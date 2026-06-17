#!/usr/bin/env bash
# Worktree mode (-W) must work in a git repo that has no 'origin' remote.
set -uo pipefail

RUN_SH="$(cd "$(dirname "$0")/.." && pwd)/run.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# repo without remote
mkdir "$TMP/repo" && cd "$TMP/repo"
git init -q
git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

# stub docker so the script never builds/runs containers
mkdir "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

OUT=$("$RUN_SH" -W --no-ssh 2>&1)

if echo "$OUT" | grep -q "no 'origin' remote"; then
    echo "FAIL: -W rejected repo without origin remote"
    echo "$OUT"
    exit 1
fi

if ! echo "$OUT" | grep -q "Creating git worktree"; then
    echo "FAIL: worktree was not created"
    echo "$OUT"
    exit 1
fi

echo "PASS"
