# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a Docker-based secure development environment for Claude Code with strict network access controls. The container restricts outbound network access to a whitelist of approved domains while maintaining full internal functionality.

## Important Design Principles

### Container Workspace Isolation

**Default behavior**: The container workspace is separate from the host directory:
- When you run `den` from a git repo, it auto-detects the origin URL and **clones** it into the container
- Each container gets its own isolated workspace at `/workspace` inside the container
- Multiple containers can run in parallel, each with their own isolated workspaces

**Git Worktree Mode** (`-W` or `--worktree`):
- Creates a git worktree in `.worktrees/<container-name>/` on your host
- Mounts the worktree to `/workspace` in the container
- Changes in the container are immediately reflected on your host filesystem
- Useful for working on the same repo in multiple branches simultaneously
- New branches are based on `origin/main` (or `origin/master` if main doesn't exist)
- If you specify an existing branch name, it checks out that branch in the worktree

**Why separate workspaces by default?**
- Keeps your host filesystem clean and isolated from container operations
- Prevents accidental modification of host files from within the container
- Each container is a fresh, reproducible environment

### Git Authentication for Push/Pull

Den supports multiple authentication methods for git operations (clone, push, pull). The methods are automatically detected and configured:

**Method 1: Git Credentials File (Recommended for HTTPS)**
```bash
# If you have ~/.git-credentials on your host, it will be automatically mounted
# Format: https://username:token@github.com
# Den auto-detects and mounts it read-only if it exists
cd ~/my-repo && den -c
```

**Method 2: SSH Keys (Recommended for SSH URLs)**
```bash
# If you have SSH keys in ~/.ssh, they will be automatically mounted
# Den copies private keys (id_rsa, id_ed25519, etc.) to the container
# Works with git@github.com:user/repo.git style URLs
cd ~/my-repo && den -c
```

**Method 3: GitHub Token (Fallback)**
```bash
# Create a token at: https://github.com/settings/tokens
# Required scopes: repo (full control of private repositories)

export GITHUB_TOKEN=ghp_yourTokenHere
cd ~/my-private-repo && den -c

# This method rewrites HTTPS URLs to inject the token
# Works for both clone and push/pull operations
```

**How it works:**
- **Git credentials**: Mounted read-only and configured with `credential.helper store`
- **SSH keys**: Copied from `~/.ssh` (excluding `*_den` keys) with proper permissions
- **GitHub token**: Rewrites `https://github.com/` to `https://git:TOKEN@github.com/`
- All methods work simultaneously - den uses whatever you have configured
- Priority: SSH keys for SSH URLs, git-credentials for HTTPS, GITHUB_TOKEN as fallback

## Architecture

The project consists of two main components:

1. **Dockerfile** - Builds a Node.js 20-based container with:
   - Claude Code CLI installed globally
   - Development tools (git, gh, zsh, fzf, etc.)
   - Network filtering tools (iptables, ipset, aggregate)
   - Non-root `node` user with sudo access for firewall management
   - Persistent command history at `/commandhistory/.bash_history`

2. **init-firewall.sh** - Network security script that:
   - Preserves Docker internal DNS (127.0.0.11) while flushing other rules
   - Creates an ipset-based whitelist of allowed IP ranges
   - Aggregates GitHub IPs from their meta API (web, api, git)
   - Resolves and whitelists specific domains (npmjs, anthropic, sentry, statsig, VS Code marketplace)
   - Allows host network communication for Docker integration
   - Blocks all other outbound traffic with verification tests

## Network Security Model

The firewall uses a **default-deny approach**:
- All outbound traffic is blocked by default (DROP policy)
- Only explicitly whitelisted destinations are allowed
- DNS resolution (UDP port 53) and SSH (TCP port 22) are permitted
- Docker internal DNS is preserved for container networking
- Host network (detected via default route) is trusted
- Verification tests ensure example.com is blocked while GitHub API is accessible

**Critical**: The firewall must be initialized after container startup using:
```bash
sudo /usr/local/bin/init-firewall.sh
```

## Key Technical Details

### Firewall Initialization Order
The init-firewall.sh script follows a specific order to avoid breaking Docker DNS:
1. Extract existing Docker DNS NAT rules before any changes
2. Flush all iptables rules and ipsets
3. Restore only the Docker DNS rules
4. Set up DNS, SSH, and localhost rules before restrictions
5. Build ipset whitelist with aggregated IP ranges
6. Apply default DROP policies
7. Allow established connections and whitelisted destinations
8. Run verification tests

### Sudoers Configuration
The `node` user has passwordless sudo access ONLY for the firewall script via:
```
/etc/sudoers.d/node-firewall
```

### IP Aggregation
GitHub IP ranges are aggregated using the `aggregate` tool to minimize ipset entries and improve performance.

## Container Configuration

- **Base image**: `debian:bookworm-slim`
- **User**: Non-root `node` user (UID matches host via `HOST_UID` build arg, default 1000)
- **Workdir**: `/workspace`
- **Shell**: zsh with oh-my-zsh and p10k theme
- **Editor**: nano (EDITOR and VISUAL env vars)
- **Claude Code**: Installed via official apt repo (signed); Node.js pulled in as dependency

## Usage

### Quick Start

The simplest way to launch a container is using the `run.sh` script:

```bash
# Basic usage - start container with SSH access
./run.sh

# Clone a repo and auto-start Claude Code
./run.sh -r https://github.com/user/repo -c

# Use git worktree (mounts .worktrees/<current-branch> to container)
cd ~/my-repo && ./run.sh -W -c

# Use git worktree with specific branch
cd ~/my-repo && ./run.sh -W feature-branch -c

# Use a Dockerfile flavor for specific project needs (e.g., Flutter)
cd ~/flutter-project && ./run.sh -c -F flutter

# With firewall and skip permissions
./run.sh -r https://github.com/user/repo -f -c -s

# Custom SSH port
./run.sh -p 3333 -r https://github.com/user/repo
```

### Dockerfile Flavors

Den supports multiple Dockerfile variants for different project requirements using the `-F` or `--flavor` flag:

**Auto-detection:**
Den automatically detects your project type and selects the appropriate flavor:
- Detects Flutter projects by checking for `pubspec.yaml` with flutter dependency
- Detects Go projects by checking for `go.mod`
- Detects Rust projects by checking for `Cargo.toml`
- More detection rules can be added for other project types

You can override auto-detection with explicit `-F` flag.

**Creating a flavor:**
1. Create a new Dockerfile with the pattern `Dockerfile.<flavor-name>` (e.g., `Dockerfile.flutter`)
2. Base it on the main `Dockerfile` or customize as needed
3. Add detection logic in `detect_flavor()` function in `run.sh` (optional)
4. Use it with: `den -c -F <flavor-name>` or let it auto-detect

**Built-in flavors:**
- `flutter` - Includes Flutter SDK for mobile app development (Dockerfile.flutter)
  - Auto-detected from `pubspec.yaml` with flutter dependency
- `go` - Includes Go toolchain and development tools (Dockerfile.go)
  - Auto-detected from `go.mod`
- `rust` - Rust toolchain (rustup stable) with `sccache` configured as `RUSTC_WRAPPER` (Dockerfile.rust)
  - Auto-detected from `Cargo.toml`
  - Auto-mounts the host's `~/.cache/sccache` (override via `SCCACHE_DIR` env var) read-write so cargo builds reuse the host's compilation cache across throwaway containers

**Example custom flavor:**
```bash
# Create Dockerfile.python for Python projects
cp Dockerfile Dockerfile.python
# Add Python-specific tools to Dockerfile.python

# Add detection in run.sh detect_flavor() function:
# if [ -f "$dir/requirements.txt" ]; then
#     echo "python"
#     return
# fi

# Use automatically (if in a Python project directory)
cd ~/my-python-project && den -c

# Or use explicitly
cd ~/my-python-project && den -c -F python
```

Each flavor builds and uses a separate Docker image (`den:<flavor>`), allowing multiple environments to coexist.

### Connecting to the Container

**SSH (direct connection):**
```bash
ssh -p 2222 node@localhost
```

**SSH with tmux (if Claude Code is running):**
```bash
ssh -p 2222 node@localhost -t tmux attach -t claude
```

**Emacs TRAMP:**
```elisp
C-x C-f /ssh:node@localhost#2222:/workspace/repo
```

### Environment Variables

The container accepts the following environment variables (set via `run.sh` flags or directly in `docker-compose.yml`):

- `REPO_URL`: Git repository URL to clone on startup
- `REPO_DIR`: Target directory for cloned repo (default: `/workspace/repo`)
- `INIT_FIREWALL`: Set to `true` to initialize firewall on startup (default: `false`)
- `START_CLAUDE`: Set to `true` to auto-start Claude Code in tmux (default: `true`)
- `SKIP_PERMISSIONS`: Set to `true` to use `--dangerously-skip-permissions` flag (default: `false`)
- `SSH_PORT`: External SSH port to expose (default: `2222`)

### Manual Docker Commands

If not using `run.sh`, you can use docker compose directly:

```bash
# Build and start
REPO_URL=https://github.com/user/repo START_CLAUDE=true docker compose up -d --build

# View logs
docker compose logs -f

# Stop and remove
docker compose down
```

Or use raw docker commands:

```bash
# Build image
docker build -t den .

# Run with SSH access
docker run -d \
  --name den \
  --cap-add NET_ADMIN \
  -p 2222:22 \
  -v ~/.ssh/id_rsa.pub:/home/node/.ssh/authorized_keys:ro \
  -v ~/.claude:/home/node/.claude \
  -e REPO_URL=https://github.com/user/repo \
  -e START_CLAUDE=true \
  den
```

## Security Considerations

When modifying this environment:
- Always test firewall changes with both positive (allowed) and negative (blocked) verification
- DNS resolution happens before IP whitelisting - ensure dig/curl work before applying restrictions
- Changes to allowed domains require rebuilding the ipset in init-firewall.sh
- The firewall script exits on any error (set -euo pipefail) to prevent partial configurations
- All IP ranges are validated with regex before being added to ipset
- SSH is configured for public key authentication only (no password login)
- Only the `node` user can login via SSH (root login disabled)
- The container requires `NET_ADMIN` capability for firewall management


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
