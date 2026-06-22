#!/usr/bin/env bash
# render_compose tests: the host-side compose-document seam. Renders the full
# docker-compose YAML from the provisioning table. Exercised with fixed fake host
# paths so the output is deterministic and golden-diffable — no docker, no real
# host config.
set -uo pipefail

LIBDIR="$(cd "$(dirname "$0")/.." && pwd)/lib"
source "$LIBDIR/provisioning.sh"
source "$LIBDIR/compose.sh"

fail() { echo "FAIL: $1"; exit 1; }

# always-row host vars -> fixed paths (should_mount=always emits regardless of
# existence, so these are deterministic). conditional rows point at nonexistent
# paths / are unset so they stay OFF for the base golden.
export SSH_PUBLIC_KEY=/fake/ssh.pub
export CLAUDE_CONFIG=/fake/claude
export CLAUDE_JSON=/fake/claude.json
export GIT_CONFIG=/fake/gitconfig
export GNUPG_DIR=/fake/gnupg
export GIT_CREDENTIALS=/nonexistent/git-credentials
export SSH_DIR=/nonexistent/ssh
export PI_CONFIG=/nonexistent/pi
export AGENTS_DIR=/nonexistent/agents
export HOST_SCCACHE_DIR=/nonexistent/sccache
export PARENT_GIT_DIR=""

# --- Behavior 1: base document (conditional mounts OFF) ----------------------
# Golden locks the scaffold + the placement of the 5 always-row mounts between
# the infra volumes and cap_add. ${...} stay literal (docker compose expands them
# at `up` time), so 'want' is also a quoted heredoc.
got=$(render_compose "")
want=$(cat <<'EOF'
services:
  den:
    image: ${IMAGE_TAG:-den:latest}
    container_name: ${CONTAINER_NAME:-den}
    hostname: ${CONTAINER_NAME:-den}
    ports:
      - "${SSH_PORT:-2222}:22"
    environment:
      - REPO_URL=${REPO_URL:-}
      - REPO_DIR=${REPO_DIR:-/workspace/repo}
      - INIT_FIREWALL=${INIT_FIREWALL:-false}
      - START_CLAUDE=${START_CLAUDE:-true}
      - START_PI=${START_PI:-false}
      - PI_EXTRA_ARGS=${PI_EXTRA_ARGS:-}
      - SKIP_PERMISSIONS=${SKIP_PERMISSIONS:-false}
      - GITHUB_TOKEN=${GITHUB_TOKEN:-}
      - GIT_USER_NAME=${GIT_USER_NAME:-}
      - GIT_USER_EMAIL=${GIT_USER_EMAIL:-}
      - HOST_HOME=${HOST_HOME:-}
    volumes:
      - ${WORKSPACE_DIR:-workspace}:/workspace
      - command-history:/commandhistory
      - claude-plugins:/home/node/.claude/plugins
      - /fake/ssh.pub:/tmp/host_ssh_key.pub:ro
      - /fake/claude:/tmp/host_claude:ro
      - /fake/claude.json:/tmp/host_claude.json:ro
      - /fake/gitconfig:/tmp/host_gitconfig:ro
      - /fake/gnupg:/home/node/.gnupg:ro
    cap_add:
      - NET_ADMIN
    stdin_open: true
    tty: true
    restart: unless-stopped

volumes:
  command-history:
  workspace:
  claude-plugins:
EOF
)
[ "$got" = "$want" ] || {
    echo "--- got ---"; printf '%s\n' "$got"
    echo "--- want ---"; printf '%s\n' "$want"
    fail "base document render mismatch"
}

# --- Behavior 2: conditional rows splice in, positioned correctly ------------
# Turn on sccache (rust flavor) and parent-git (worktree, if-set). Both must
# appear AND sit between the `volumes:` block and `cap_add:` — the invariant the
# old sed marker line used to guarantee.
export HOST_SCCACHE_DIR=/fake/sccache
export PARENT_GIT_DIR=/fake/parent.git
out=$(render_compose rust)

scc_line='      - /fake/sccache:/home/node/.cache/sccache:rw'
pgit_line='      - /fake/parent.git:/fake/parent.git:rw'   # __SELF__: target == host
printf '%s\n' "$out" | grep -qF "$scc_line" || fail "rust sccache mount missing"
printf '%s\n' "$out" | grep -qF "$pgit_line" || fail "worktree parent-git mount missing"

line_no() { printf '%s\n' "$out" | grep -nF "$1" | head -1 | cut -d: -f1; }
vol_ln=$(printf '%s\n' "$out" | grep -n '^    volumes:$' | cut -d: -f1)
cap_ln=$(printf '%s\n' "$out" | grep -n '^    cap_add:$' | cut -d: -f1)
for m in "$scc_line" "$pgit_line"; do
    mln=$(line_no "$m")
    [ "$vol_ln" -lt "$mln" ] && [ "$mln" -lt "$cap_ln" ] \
        || fail "mount [$m] (line $mln) not between volumes: ($vol_ln) and cap_add: ($cap_ln)"
done

echo "PASS"
