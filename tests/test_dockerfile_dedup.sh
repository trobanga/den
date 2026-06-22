#!/usr/bin/env bash
# Deletion test for den-7yk: the common base must live in ONE definition.
# Dockerfile is den:base; Dockerfile.go / Dockerfile.rust are thin `FROM den:base`
# deltas. If a future edit re-pastes the base into a flavor file, the near-identical
# blocks reappear here and this test fails — the dedup earns its keep.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# First non-blank, non-comment line of a Dockerfile (its FROM).
first_from() { grep -vE '^[[:space:]]*(#|$)' "$1" | head -1; }

# Markers that belong to the shared base ONLY — must not recur in a derived flavor.
BASE_MARKERS=(openssh-server deb.nodesource.com 'beads/main/scripts/install.sh' \
              node-firewall ssh-keyscan zsh-in-docker)

assert_base_owns() {           # $1 = derived Dockerfile
  local f="$REPO/$1" m
  [ "$(first_from "$f")" = "FROM den:base" ] || fail "$1 must start: FROM den:base"
  # Scan instructions only — a comment referencing the base is fine; a re-pasted
  # build step is not. Strip comment lines before matching.
  local instructions; instructions=$(grep -vE '^[[:space:]]*#' "$f")
  for m in "${BASE_MARKERS[@]}"; do
    grep -qF "$m" "$REPO/Dockerfile" || fail "base marker '$m' missing from Dockerfile (base)"
    printf '%s\n' "$instructions" | grep -qF "$m" && \
      fail "$1 re-duplicates base marker '$m' (belongs in den:base)"
  done
  return 0
}

# --- go: FROM den:base + only the Go toolchain delta ---------------------------
assert_base_owns Dockerfile.go
grep -qF 'go.dev/dl' "$REPO/Dockerfile.go" || fail "Dockerfile.go lost its Go toolchain delta"

# --- rust: FROM den:base + only the Rust toolchain delta -----------------------
assert_base_owns Dockerfile.rust
grep -qF 'sh.rustup.rs' "$REPO/Dockerfile.rust" || fail "Dockerfile.rust lost its rustup delta"
grep -qF 'sccache'      "$REPO/Dockerfile.rust" || fail "Dockerfile.rust lost its sccache delta"

echo "PASS"
