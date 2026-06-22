# Host→container provisioning seam: data-driven provisioning

**Issue:** den-sj7.1 (epic den-sj7 — deepen run.sh)
**Date:** 2026-06-20
**Status:** Approved

## Problem

One concept — *provision a host artifact into the container* — is shattered across
3 disjoint edit sites in 2 files / 2 languages:

- `run.sh` heredoc — hardcoded artifact volume lines (always-present mounts)
- `run.sh` `sed -i` injection blocks — conditional mounts (git-creds, ssh-host, pi, sccache, parent-git)
- `entrypoint.sh` — copy-and-chmod blocks (claude, claude.json, pi, gitconfig)

Adding one config touches all three. No module owns *what gets provisioned*. The
`sed -i '/^    cap_add:/i ...'` injection is especially brittle — it depends on a
literal anchor line and silently breaks if the compose scaffold changes.

## Solution

Provisioning as **data**: a single table, sourced by both the host emitter and the
container provisioner. Adding a config becomes adding one row.

### Scope decisions (resolved during brainstorming)

1. **Full cross-language seam** — one shared table feeds *both* `run.sh` (mount emit)
   and `entrypoint.sh` (container copy). Single source of truth.
2. **Uniform-in-table, ssh-* bespoke** — the table owns the artifacts that follow the
   uniform `cp [-r]; chmod` pattern, plus folds mount-only artifacts as no-copy rows.
   `ssh-key` (special dest `authorized_keys` + dual perms) and `ssh-host` (`find`-based
   selective copy) stay as bespoke functions in `entrypoint.sh` — they are *not*
   near-identical to anything, and forcing them into the table would build the leaky
   dispatch-table that deepening is meant to avoid. They still appear in the table as
   **mount-only** rows (`copy_kind=none`) so the host still emits their mounts from the
   single source; only their container-side copy stays bespoke.

## Architecture

### New file: `lib/provisioning.sh`

The single source of truth. Sourced by:
- `run.sh` on the host: `source "$SCRIPT_DIR/lib/provisioning.sh"`
- `entrypoint.sh` in the container: `source /usr/local/lib/provisioning.sh`
  (baked into the image by each Dockerfile)

### The table

One row per artifact, `|`-delimited fields:

```
name | host_var | mount_target | mode | host_cond | copy_kind | final_dest | perm
```

| name        | host_var          | mount_target                  | mode | host_cond | copy_kind | final_dest                | perm |
|-------------|-------------------|-------------------------------|------|-----------|-----------|---------------------------|------|
| ssh-key     | SSH_PUBLIC_KEY    | /tmp/host_ssh_key.pub         | ro   | always    | none      | -                         | -    |
| claude      | CLAUDE_CONFIG     | /tmp/host_claude              | ro   | always    | dir       | /home/node/.claude        | u+w  |
| claude-json | CLAUDE_JSON       | /tmp/host_claude.json         | ro   | always    | file      | /home/node/.claude.json   | 644  |
| gitconfig   | GIT_CONFIG        | /tmp/host_gitconfig           | ro   | always    | file      | /home/node/.gitconfig     | 644  |
| gnupg       | GNUPG_DIR         | /home/node/.gnupg             | ro   | always    | none      | -                         | -    |
| git-creds   | GIT_CREDENTIALS   | /home/node/.git-credentials   | ro   | if-file   | none      | -                         | -    |
| ssh-host    | SSH_DIR           | /home/node/.ssh-host          | ro   | if-dir    | none      | -                         | -    |
| pi          | PI_CONFIG         | /tmp/host_pi                  | ro   | if-dir    | dir       | /home/node/.pi            | u+w  |
| sccache     | HOST_SCCACHE_DIR  | /home/node/.cache/sccache     | rw   | if-rust   | none      | -                         | -    |
| parent-git  | PARENT_GIT_DIR    | `__SELF__`                    | rw   | if-set    | none      | -                         | -    |

**Field semantics:**
- `host_var` — name of the env var holding the resolved host path; resolved via
  bash indirect expansion `${!host_var}` (every one is already exported by `run.sh`
  as a full absolute path).
- `mount_target` — container path the bind mount lands at. `__SELF__` sentinel means
  "mount target == host path" (the worktree parent-`.git` case, mounted at the same
  absolute path on both sides).
- `mode` — `ro` / `rw`. (`rw` ≡ bind-mount default; emitted explicitly.)
- `host_cond` — `always` | `if-file` | `if-dir` | `if-set` | `if-rust`. Decides whether
  `run.sh` emits the mount.
- `copy_kind` — `none` | `file` | `dir`. Decides container-side copy. `none` = mounted
  in place, no copy.
- `final_dest`, `perm` — used only when `copy_kind != none`.

### Functions in `lib/provisioning.sh`

- `format_mount(host_path, target, mode)` — **pure** string transform →
  `      - host_path:target:mode`. No filesystem, no docker. The issue's named
  testable seam.
- `should_mount(host_path, host_cond, flavor)` — predicate; evaluates `host_cond`
  against the filesystem / flavor.
- `emit_mounts(flavor)` — iterates the table; resolves `${!host_var}` (applying
  `__SELF__`); for rows where `should_mount` is true, prints `format_mount`. This is
  what `run.sh` splices into the compose `volumes:` section.
- `provision_artifacts(root="")` — iterates the table; for `copy_kind ∈ {file, dir}`,
  if `${root}${mount_target}` exists: `file` → `cp; chmod perm`; `dir` →
  `rm -rf; cp -r; chmod -R perm`. The `root` prefix (default empty) makes the copy
  logic testable on the host without docker.

## Wiring changes

### `run.sh`
- `source` the lib near the top.
- **Delete all 5 `sed -i` injection blocks** and the hardcoded artifact volume lines
  in the heredoc.
- Build the compose file as `top-heredoc + emit_mounts + bottom-heredoc` — no `sed` at
  all. The top heredoc carries the scaffold through `    volumes:` plus the infra
  mounts (`workspace`, `command-history`); `emit_mounts` supplies all artifact lines;
  the bottom heredoc carries `cap_add`, tty/restart, and the `volumes:` named-volume
  section.
- The `sccache mkdir -p "$HOST_SCCACHE_DIR"` side-effect stays in `run.sh` (keeps
  `emit_mounts` pure).

### `entrypoint.sh`
- `source /usr/local/lib/provisioning.sh`.
- Replace the 4 copy blocks (claude, claude.json, pi, gitconfig) with a single
  `provision_artifacts` call.
- **Keep bespoke:** ssh-key (authorized_keys + mkdir + 700/600), ssh-host (find-filter
  copy), git-cred helper config, GITHUB_TOKEN url-rewrite, git-identity. These are
  out of scope (git-auth de-triplication is den-sj7.3).

### Dockerfiles (×4: `Dockerfile`, `.flutter`, `.go`, `.rust`)
- Add `COPY lib/provisioning.sh /usr/local/lib/provisioning.sh` adjacent to the
  existing `COPY entrypoint.sh /usr/local/bin/` line (late layer → minimal cache
  invalidation).

## Testing (TDD, standalone `.sh` matching `tests/` convention)

- `tests/test_format_mount.sh` — pure assertions on `format_mount`, then `emit_mounts`
  across scenarios: default, +git-credentials, +pi, rust flavor, worktree
  (`PARENT_GIT_DIR` set). Includes the **deletion test**: stub out the loop and watch
  near-identical pairs reappear, proving the abstraction earns its keep.
- `tests/test_provision_artifacts.sh` — temp `root`; create fake `mount_target`s;
  assert files/dirs copied to `final_dest` with correct perms; assert `copy_kind=none`
  rows are skipped.
- `tests/test_worktree_no_remote.sh` — existing; must stay green (integration smoke
  that `run.sh -W` still emits mounts and creates the worktree).
- Add a `test` recipe to the `Justfile` that runs `tests/*.sh`.

## Behavior preservation

This is a refactor — observable behavior must not change:
- **gnupg** stays an *unconditional* mount (`host_cond=always`), preserving the existing
  quirk that it mounts even when `~/.gnupg` is absent.
- `:rw` is emitted explicitly where bind mounts previously relied on the default; these
  are equivalent.
- The emitted volume *set* must match the prior output for each scenario — verified by
  the `emit_mounts` scenario tests.

## Build sequence (tracer-bullet slices)

1. `format_mount` — one failing test → minimal pure fn.
2. `should_mount` + `emit_mounts` — scenario tests → table + loop.
3. Wire `run.sh` to use `emit_mounts`; delete sed blocks; `test_worktree_no_remote` green.
4. `provision_artifacts` — temp-root test → copy loop.
5. Wire `entrypoint.sh` to use `provision_artifacts`; delete 4 copy blocks.
6. Dockerfiles ×4: COPY the lib.
7. Justfile `test` recipe.

## Out of scope

- Git-auth de-triplication / `GIT_CONFIG_GLOBAL` bootstrap (den-sj7.3).
- Compose assembly overhaul beyond removing sed injection (den-sj7.2).
- Dockerfile base-stage collapse (den-7yk).
