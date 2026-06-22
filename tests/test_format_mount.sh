#!/usr/bin/env bash
# Pure-function tests for the provisioning seam: format_mount + emit_mounts.
# No docker, no container — these exercise the host-side emitter in isolation.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/provisioning.sh"
source "$LIB"

fail() { echo "FAIL: $1"; exit 1; }

# --- format_mount: pure (host_path, target, mode) -> one compose volume line ---
got=$(format_mount /home/u/.ssh/id.pub /tmp/host_ssh_key.pub ro)
want="      - /home/u/.ssh/id.pub:/tmp/host_ssh_key.pub:ro"
[ "$got" = "$want" ] || fail "format_mount basic: got [$got] want [$want]"

# --- emit_mounts scenarios ---------------------------------------------------
# emit_mounts reads the host_var env vars + filesystem + flavor and prints the
# set of compose volume lines. The tests control env vars so no real host config
# leaks in. TMP holds the conditional artifacts we toggle per scenario.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The five always-mounted artifacts: fixed recognizable paths, existence-independent.
always_env() {
    export SSH_PUBLIC_KEY=/h/.ssh/id.pub
    export CLAUDE_CONFIG=/h/.claude
    export CLAUDE_JSON=/h/.claude.json
    export GIT_CONFIG=/h/.gitconfig
    export GNUPG_DIR=/h/.gnupg
}

# Conditional artifacts default to non-existent / unset so a bare scenario emits
# only the always-mounts. Each scenario flips exactly one on.
clear_conditionals() {
    export GIT_CREDENTIALS="$TMP/none-creds"
    export SSH_DIR="$TMP/none-ssh"
    export PI_CONFIG="$TMP/none-pi"
    export AGENTS_DIR="$TMP/none-agents"
    export HOST_SCCACHE_DIR="$TMP/sccache"
    export PARENT_GIT_DIR=""
}

ALWAYS_LINES="      - /h/.ssh/id.pub:/tmp/host_ssh_key.pub:ro
      - /h/.claude:/tmp/host_claude:ro
      - /h/.claude.json:/tmp/host_claude.json:ro
      - /h/.gitconfig:/tmp/host_gitconfig:ro
      - /h/.gnupg:/home/node/.gnupg:ro"

# Scenario: default — nothing conditional present, no flavor.
always_env; clear_conditionals
got=$(emit_mounts "")
[ "$got" = "$ALWAYS_LINES" ] || fail "emit default: got
[$got]
want
[$ALWAYS_LINES]"

# Scenario: +git-credentials (if-file) — file present -> one extra mount.
always_env; clear_conditionals
touch "$TMP/creds"; export GIT_CREDENTIALS="$TMP/creds"
got=$(emit_mounts "")
want="$ALWAYS_LINES
      - $TMP/creds:/home/node/.git-credentials:ro"
[ "$got" = "$want" ] || fail "emit +git-credentials: got
[$got]
want
[$want]"

# Scenario: +ssh-host (if-dir) — directory present -> one extra mount.
always_env; clear_conditionals
mkdir -p "$TMP/ssh"; export SSH_DIR="$TMP/ssh"
got=$(emit_mounts "")
want="$ALWAYS_LINES
      - $TMP/ssh:/home/node/.ssh-host:ro"
[ "$got" = "$want" ] || fail "emit +ssh-host: got
[$got]
want
[$want]"

# Scenario: +pi (if-dir) — directory present -> one extra mount.
always_env; clear_conditionals
mkdir -p "$TMP/pi"; export PI_CONFIG="$TMP/pi"
got=$(emit_mounts "")
want="$ALWAYS_LINES
      - $TMP/pi:/tmp/host_pi:ro"
[ "$got" = "$want" ] || fail "emit +pi: got
[$got]
want
[$want]"

# Scenario: +agents (if-dir) — directory present -> one extra mount.
always_env; clear_conditionals
mkdir -p "$TMP/agents"; export AGENTS_DIR="$TMP/agents"
got=$(emit_mounts "")
want="$ALWAYS_LINES
      - $TMP/agents:/tmp/host_agents:ro"
[ "$got" = "$want" ] || fail "emit +agents: got
[$got]
want
[$want]"

# Scenario: rust flavor (if-rust) — sccache mount appears, gated by flavor only
# (not by the dir existing — run.sh mkdir's it before emitting).
always_env; clear_conditionals
export HOST_SCCACHE_DIR="$TMP/sccache"
got=$(emit_mounts "rust")
want="$ALWAYS_LINES
      - $TMP/sccache:/home/node/.cache/sccache:rw"
[ "$got" = "$want" ] || fail "emit rust flavor: got
[$got]
want
[$want]"

# Non-rust flavor must NOT emit the sccache mount even if the var is set.
always_env; clear_conditionals
export HOST_SCCACHE_DIR="$TMP/sccache"
got=$(emit_mounts "go")
[ "$got" = "$ALWAYS_LINES" ] || fail "emit go flavor must skip sccache: got
[$got]"

# Scenario: worktree (if-set) — PARENT_GIT_DIR set -> __SELF__ mount (target==host
# path, mode rw, no separate container target).
always_env; clear_conditionals
export PARENT_GIT_DIR="/home/u/proj/.git"
got=$(emit_mounts "")
want="$ALWAYS_LINES
      - /home/u/proj/.git:/home/u/proj/.git:rw"
[ "$got" = "$want" ] || fail "emit worktree: got
[$got]
want
[$want]"

# Leverage / deletion check: with every conditional on, ONE loop emits exactly
# one line per table row (11). Delete the loop and these 11 lines must be
# hand-maintained across both run.sh and entrypoint.sh — the duplication this
# seam removes. The count guards against rows silently dropping out.
always_env; clear_conditionals
touch "$TMP/creds"; export GIT_CREDENTIALS="$TMP/creds"
mkdir -p "$TMP/ssh" "$TMP/pi" "$TMP/agents"
export SSH_DIR="$TMP/ssh" PI_CONFIG="$TMP/pi" AGENTS_DIR="$TMP/agents"
export HOST_SCCACHE_DIR="$TMP/sccache" PARENT_GIT_DIR="/home/u/proj/.git"
n=$(emit_mounts "rust" | grep -c '^      - ')
[ "$n" -eq 11 ] || fail "emit all-on: expected 11 mount lines, got $n"

echo "PASS"
