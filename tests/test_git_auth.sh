#!/usr/bin/env bash
# git-auth module tests: the single source of truth for the container's effective
# git config. Exercised on the host via a `home` prefix + GIT_CONFIG_EXTRA
# override so no docker / real /home/node / real /tmp is touched.
set -uo pipefail

LIB="$(cd "$(dirname "$0")/.." && pwd)/lib/git-auth.sh"
source "$LIB"

fail() { echo "FAIL: $1"; exit 1; }

# --- ensure_git_config_global: sets+exports GIT_CONFIG_GLOBAL, persists to shells
HOME1=$(mktemp -d)
trap 'rm -rf "$HOME1"' EXIT
: > "$HOME1/.bashrc"
unset GIT_CONFIG_GLOBAL
GIT_CONFIG_EXTRA="$HOME1/.gitconfig-extra"

ensure_git_config_global "$HOME1"

[ "${GIT_CONFIG_GLOBAL:-}" = "$HOME1/.gitconfig-extra" ] \
    || fail "GIT_CONFIG_GLOBAL not exported to extra path: got [${GIT_CONFIG_GLOBAL:-}]"
grep -qF "export GIT_CONFIG_GLOBAL=$HOME1/.gitconfig-extra" "$HOME1/.bashrc" \
    || fail "export line not appended to .bashrc"

# --- idempotent: a second call (already set) must not re-append --------------
ensure_git_config_global "$HOME1"
n=$(grep -cF "export GIT_CONFIG_GLOBAL=" "$HOME1/.bashrc")
[ "$n" -eq 1 ] || fail "export line appended $n times, want 1 (not idempotent)"

# --- .zshrc appended only when present; .profile created when absent ----------
HOME2=$(mktemp -d)
: > "$HOME2/.bashrc"
: > "$HOME2/.zshrc"            # present -> must get the export
# .profile intentionally absent -> must be created
unset GIT_CONFIG_GLOBAL
GIT_CONFIG_EXTRA="$HOME2/.gitconfig-extra"
ensure_git_config_global "$HOME2"
grep -qF "export GIT_CONFIG_GLOBAL=$HOME2/.gitconfig-extra" "$HOME2/.zshrc" \
    || fail "export line not appended to existing .zshrc"
[ -f "$HOME2/.profile" ] \
    && grep -qF "export GIT_CONFIG_GLOBAL=$HOME2/.gitconfig-extra" "$HOME2/.profile" \
    || fail "export line not written to created .profile"
rm -rf "$HOME2"

# absent .zshrc must not be conjured
HOME3=$(mktemp -d)
: > "$HOME3/.bashrc"           # no .zshrc
unset GIT_CONFIG_GLOBAL
GIT_CONFIG_EXTRA="$HOME3/.gitconfig-extra"
ensure_git_config_global "$HOME3"
[ ! -e "$HOME3/.zshrc" ] || fail "absent .zshrc must not be created"
rm -rf "$HOME3"

# --- setup_git_auth: identity env vars -> git config global shows them --------
HOME4=$(mktemp -d)
: > "$HOME4/.bashrc"
unset GIT_CONFIG_GLOBAL GITHUB_TOKEN          # isolate the identity method
GIT_CONFIG_EXTRA="$HOME4/.gitconfig-extra"
GIT_USER_NAME="Ada Lovelace" GIT_USER_EMAIL="ada@example.com" setup_git_auth "$HOME4"
got_name=$(GIT_CONFIG_GLOBAL="$HOME4/.gitconfig-extra" git config --global user.name)
got_email=$(GIT_CONFIG_GLOBAL="$HOME4/.gitconfig-extra" git config --global user.email)
[ "$got_name" = "Ada Lovelace" ] || fail "git user.name not configured: got [$got_name]"
[ "$got_email" = "ada@example.com" ] || fail "git user.email not configured: got [$got_email]"
grep -qF "export GIT_CONFIG_GLOBAL=$HOME4/.gitconfig-extra" "$HOME4/.bashrc" \
    || fail "setup_git_auth did not bootstrap GIT_CONFIG_GLOBAL"
rm -rf "$HOME4"

# --- setup_git_auth: credentials file present -> credential.helper store ------
HOME5=$(mktemp -d)
: > "$HOME5/.bashrc"
: > "$HOME5/.git-credentials"                 # presence is the trigger
unset GIT_CONFIG_GLOBAL GITHUB_TOKEN GIT_USER_NAME GIT_USER_EMAIL
GIT_CONFIG_EXTRA="$HOME5/.gitconfig-extra"
setup_git_auth "$HOME5"
got_helper=$(GIT_CONFIG_GLOBAL="$HOME5/.gitconfig-extra" git config --global credential.helper)
[ "$got_helper" = "store" ] || fail "credential.helper not 'store': got [$got_helper]"
rm -rf "$HOME5"

# --- setup_git_auth: GITHUB_TOKEN -> url insteadOf rewrite --------------------
HOME6=$(mktemp -d)
: > "$HOME6/.bashrc"
unset GIT_CONFIG_GLOBAL GIT_USER_NAME GIT_USER_EMAIL
GIT_CONFIG_EXTRA="$HOME6/.gitconfig-extra"
GITHUB_TOKEN="ghp_test123" setup_git_auth "$HOME6"
got_rewrite=$(GIT_CONFIG_GLOBAL="$HOME6/.gitconfig-extra" \
    git config --global url."https://git:ghp_test123@github.com/".insteadOf)
[ "$got_rewrite" = "https://github.com/" ] || fail "token url rewrite missing: got [$got_rewrite]"
rm -rf "$HOME6"

# --- setup_git_auth: no methods configured -> no-op (no bootstrap, no config) -
HOME7=$(mktemp -d)
: > "$HOME7/.bashrc"
unset GIT_CONFIG_GLOBAL GITHUB_TOKEN GIT_USER_NAME GIT_USER_EMAIL
GIT_CONFIG_EXTRA="$HOME7/.gitconfig-extra"
setup_git_auth "$HOME7"
[ ! -s "$HOME7/.bashrc" ] || fail "no-op path still wrote to .bashrc"
[ ! -e "$HOME7/.gitconfig-extra" ] || fail "no-op path still wrote git config"
rm -rf "$HOME7"

echo "PASS"
