#!/usr/bin/env bash
# provision_artifacts copies mounted artifacts into place. Exercised on the host
# via a temp `root` prefix so no docker / real /home/node is needed.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/provisioning.sh"
source "$LIB"

fail() { echo "FAIL: $1"; exit 1; }

# --- present sources: every copy_kind row is provisioned -----------------------
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT" "${ROOT2:-}"' EXIT

mkdir -p "$ROOT/home/node" "$ROOT/tmp"          # container home pre-exists in the image
printf 'CLAUDEJSON\n' > "$ROOT/tmp/host_claude.json"
printf 'GITCONFIG\n'  > "$ROOT/tmp/host_gitconfig"
mkdir -p "$ROOT/tmp/host_pi";     printf 'PI\n'     > "$ROOT/tmp/host_pi/conf"
mkdir -p "$ROOT/tmp/host_agents"; printf 'AGENTS\n' > "$ROOT/tmp/host_agents/skill"
# A mount-only (copy_kind=none) source present too: must be left untouched.
mkdir -p "$ROOT/tmp/host_claude"; printf 'X\n' > "$ROOT/tmp/host_claude/settings"

provision_artifacts "$ROOT"

# file rows: content copied + perm 644
[ -f "$ROOT/home/node/.claude.json" ] || fail "claude.json not copied"
[ "$(cat "$ROOT/home/node/.claude.json")" = "CLAUDEJSON" ] || fail "claude.json content"
[ "$(stat -c %a "$ROOT/home/node/.claude.json")" = "644" ] || fail "claude.json perm not 644"
[ -f "$ROOT/home/node/.gitconfig" ] || fail "gitconfig not copied"
[ "$(stat -c %a "$ROOT/home/node/.gitconfig")" = "644" ] || fail "gitconfig perm not 644"

# dir rows: content copied + made writable (chmod -R u+w)
[ -d "$ROOT/home/node/.pi" ] || fail "pi not copied"
[ "$(cat "$ROOT/home/node/.pi/conf")" = "PI" ] || fail "pi content"
[ -w "$ROOT/home/node/.pi" ] || fail "pi dir not writable"
[ -d "$ROOT/home/node/.agents" ] || fail "agents not copied"
[ "$(cat "$ROOT/home/node/.agents/skill")" = "AGENTS" ] || fail "agents content"
[ -w "$ROOT/home/node/.agents" ] || fail "agents dir not writable"

# copy_kind=none rows are skipped: claude is bespoke (plugins-preserving copy
# stays in entrypoint.sh) -> provision_artifacts must NOT create /home/node/.claude.
[ ! -e "$ROOT/home/node/.claude" ] || fail "claude (copy_kind=none) must not be provisioned"

# --- absent sources: rows whose mount_target is missing are skipped, no error --
ROOT2=$(mktemp -d)
mkdir -p "$ROOT2/home/node" "$ROOT2/tmp"        # no source artifacts created
provision_artifacts "$ROOT2" || fail "provision_artifacts errored on absent sources"
[ ! -e "$ROOT2/home/node/.claude.json" ] || fail "claude.json conjured from nothing"
[ ! -e "$ROOT2/home/node/.pi" ] || fail "pi conjured from nothing"

echo "PASS"
