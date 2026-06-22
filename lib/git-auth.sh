# shellcheck shell=bash
# Git-auth module: the single source of truth for the container's effective git
# config. The 3 auth methods (credentials file / GITHUB_TOKEN / identity) all
# funnel through ensure_git_config_global instead of each re-implementing the
# GIT_CONFIG_GLOBAL bootstrap. Sourced by entrypoint.sh (guest).

# Where the layered, container-only git config lives. Overridable for host tests.
GIT_CONFIG_EXTRA="${GIT_CONFIG_EXTRA:-/tmp/.gitconfig-extra}"

# ensure_git_config_global: idempotently point GIT_CONFIG_GLOBAL at the layered
# extra config and persist that export into the user's shells, so the same config
# is in effect for the entrypoint and every interactive login. `home` (default
# /home/node) prefixes the rc files so this is testable on the host.
ensure_git_config_global() {
    local home="${1:-/home/node}"
    [ -n "${GIT_CONFIG_GLOBAL:-}" ] && return 0
    export GIT_CONFIG_GLOBAL="$GIT_CONFIG_EXTRA"
    local line="export GIT_CONFIG_GLOBAL=$GIT_CONFIG_EXTRA"
    echo "$line" >> "$home/.bashrc"
    [ -f "$home/.zshrc" ] && echo "$line" >> "$home/.zshrc"
    # .profile is the login-shell entry; create it if the image didn't ship one.
    if [ -f "$home/.profile" ]; then
        echo "$line" >> "$home/.profile"
    else
        echo "$line" > "$home/.profile"
    fi
}

# setup_git_auth: the git-auth module's single entry point. Reads the environment
# (a mounted credentials file, GITHUB_TOKEN, GIT_USER_NAME/EMAIL) and applies
# every method that is configured — they layer, they don't compete. Each funnels
# through ensure_git_config_global so the bootstrap lives in exactly one place.
# `home` (default /home/node) prefixes paths so this is testable on the host.
setup_git_auth() {
    local home="${1:-/home/node}"

    # HTTPS push/pull via a mounted ~/.git-credentials store.
    if [ -f "$home/.git-credentials" ]; then
        echo "git-auth: credentials file -> credential.helper store"
        ensure_git_config_global "$home"
        git config --global credential.helper store
    fi

    # Fallback: inject a token into GitHub HTTPS URLs.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "git-auth: GITHUB_TOKEN url rewrite"
        ensure_git_config_global "$home"
        git config --global url."https://git:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
    fi

    if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
        echo "git-auth: identity $GIT_USER_NAME <$GIT_USER_EMAIL>"
        ensure_git_config_global "$home"
        git config --global user.name "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
    fi
}
