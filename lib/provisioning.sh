# shellcheck shell=bash
# Provisioning seam: the single source of truth for which host artifacts get
# provisioned into the container, and how. Sourced by both sides of the seam:
#   - run.sh (host)        -> emits the compose `volumes:` mount lines
#   - entrypoint.sh (guest) -> copies mounted artifacts into place
# Adding a provisioned artifact is one new table row, not edits across two files.

# The provisioning table. One row per artifact, `|`-delimited fields:
#
#   name | host_var | mount_target | mode | host_cond | copy_kind | final_dest | perm
#
#   host_var     env var (in run.sh) holding the resolved absolute host path;
#                read here via bash indirect expansion ${!host_var}.
#   mount_target container path the bind mount lands at. `__SELF__` means the
#                mount target equals the host path (worktree parent-.git case).
#   mode         ro | rw  (rw == bind-mount default; emitted explicitly).
#   host_cond    always | if-file | if-dir | if-set | if-rust — gates the mount.
#   copy_kind    none | file | dir — gates the container-side copy.
#                none = mounted in place, no copy (bespoke or mount-only).
#   final_dest,
#   perm         used only when copy_kind != none.
#
# Bespoke-by-design (copy_kind=none, copy stays hand-written in entrypoint.sh):
#   ssh-key  -> authorized_keys + 700/600 (special dest + dual perms)
#   ssh-host -> find-filtered selective copy
#   claude   -> preserves the claude-plugins volume + first-run plugins cache
# Forcing these into the uniform copy loop would wipe the plugins volume and
# rebuild the leaky dispatch-table this seam exists to avoid. They still live in
# the table as mount-only rows so the host emits their mounts from one source.
PROVISION_TABLE="\
ssh-key|SSH_PUBLIC_KEY|/tmp/host_ssh_key.pub|ro|always|none|-|-
claude|CLAUDE_CONFIG|/tmp/host_claude|ro|always|none|-|-
claude-json|CLAUDE_JSON|/tmp/host_claude.json|ro|always|file|/home/node/.claude.json|644
gitconfig|GIT_CONFIG|/tmp/host_gitconfig|ro|always|file|/home/node/.gitconfig|644
gnupg|GNUPG_DIR|/home/node/.gnupg|ro|always|none|-|-
git-creds|GIT_CREDENTIALS|/home/node/.git-credentials|ro|if-file|none|-|-
ssh-host|SSH_DIR|/home/node/.ssh-host|ro|if-dir|none|-|-
pi|PI_CONFIG|/tmp/host_pi|ro|if-dir|dir|/home/node/.pi|u+w
agents|AGENTS_DIR|/tmp/host_agents|ro|if-dir|dir|/home/node/.agents|u+w
sccache|HOST_SCCACHE_DIR|/home/node/.cache/sccache|rw|if-rust|none|-|-
parent-git|PARENT_GIT_DIR|__SELF__|rw|if-set|none|-|-"

# format_mount: pure transform. (host_path, target, mode) -> one compose volume line.
# No filesystem, no docker — the named, assertable seam.
format_mount() {
    printf '      - %s:%s:%s\n' "$1" "$2" "$3"
}

# should_mount: predicate. (host_path, host_cond, flavor) -> 0 if the mount applies.
should_mount() {
    local host_path="$1" host_cond="$2" flavor="$3"
    case "$host_cond" in
        always)  return 0 ;;
        if-file) [ -f "$host_path" ] ;;
        if-dir)  [ -d "$host_path" ] ;;
        if-set)  [ -n "$host_path" ] ;;
        if-rust) [ "$flavor" = "rust" ] ;;
        *)       return 1 ;;
    esac
}

# emit_mounts: iterate the table; for rows whose host_cond holds, print the
# compose volume line. Resolves ${!host_var} per row and applies the __SELF__
# sentinel (mount target == host path). Pure w.r.t. side effects — only reads
# env + filesystem, writes to stdout. This is what run.sh splices into volumes:.
emit_mounts() {
    local flavor="${1:-}"
    local name host_var mount_target mode host_cond copy_kind final_dest perm
    local host_path target
    while IFS='|' read -r name host_var mount_target mode host_cond copy_kind final_dest perm; do
        [ -n "$name" ] || continue
        host_path="${!host_var:-}"
        if [ "$mount_target" = "__SELF__" ]; then
            target="$host_path"
        else
            target="$mount_target"
        fi
        if should_mount "$host_path" "$host_cond" "$flavor"; then
            format_mount "$host_path" "$target" "$mode"
        fi
    done <<< "$PROVISION_TABLE"
}

# provision_artifacts: container-side copy. Iterate the table; for copy_kind
# file/dir rows whose mounted source exists, copy it to final_dest and apply perm.
# `root` (default empty) prefixes every path so the copy logic is testable on the
# host without docker. copy_kind=none rows are mounted in place (or bespoke) and
# skipped here.
provision_artifacts() {
    local root="${1:-}"
    local name host_var mount_target mode host_cond copy_kind final_dest perm
    local src dest
    while IFS='|' read -r name host_var mount_target mode host_cond copy_kind final_dest perm; do
        [ -n "$name" ] || continue
        src="${root}${mount_target}"
        dest="${root}${final_dest}"
        case "$copy_kind" in
            file)
                if [ -f "$src" ]; then
                    cp "$src" "$dest"
                    chmod "$perm" "$dest"
                fi
                ;;
            dir)
                if [ -d "$src" ]; then
                    rm -rf "$dest"
                    cp -r "$src" "$dest"
                    chmod -R "$perm" "$dest"
                fi
                ;;
            *) : ;;  # none: mounted in place / bespoke copy in entrypoint.sh
        esac
    done <<< "$PROVISION_TABLE"
}
