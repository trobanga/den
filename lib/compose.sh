# shellcheck shell=bash
# Compose-document seam (host-only, used by run.sh): render the full
# docker-compose YAML from the provisioning table. Pure transform — scaffold +
# emit_mounts (artifact mounts) + tail, all to stdout. No side effects (the rust
# sccache mkdir stays in run.sh). Depends on emit_mounts from provisioning.sh,
# which run.sh and the test source alongside this file.

# render_compose: (flavor) -> complete docker-compose YAML on stdout. The ${...}
# tokens stay literal (quoted heredoc) so `docker compose` interpolates them from
# the environment at `up` time; only emit_mounts resolves real host paths. The
# named, golden-testable compose seam.
render_compose() {
    local flavor="${1:-}"
    cat <<'EOF'
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
EOF
    emit_mounts "$flavor"
    cat <<'EOF'
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
}
