# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains a Docker-based secure development environment for Claude Code with strict network access controls. The container restricts outbound network access to a whitelist of approved domains while maintaining full internal functionality.

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

- **User**: Non-root `node` user (UID 1000)
- **Workdir**: `/workspace`
- **Shell**: zsh with oh-my-zsh and p10k theme
- **Editor**: nano (EDITOR and VISUAL env vars)
- **Node Version**: 20
- **Claude Code**: Installed globally, version controlled via build arg

## Usage

### Quick Start

The simplest way to launch a container is using the `run.sh` script:

```bash
# Basic usage - start container with SSH access
./run.sh

# Clone a repo and auto-start Claude Code
./run.sh -r https://github.com/user/repo -c

# With firewall and skip permissions
./run.sh -r https://github.com/user/repo -f -c -s

# Custom SSH port
./run.sh -p 3333 -r https://github.com/user/repo
```

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
docker build -t clauntainer .

# Run with SSH access
docker run -d \
  --name clauntainer \
  --cap-add NET_ADMIN \
  -p 2222:22 \
  -v ~/.ssh/id_rsa.pub:/home/node/.ssh/authorized_keys:ro \
  -v ~/.claude:/home/node/.claude \
  -e REPO_URL=https://github.com/user/repo \
  -e START_CLAUDE=true \
  clauntainer
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
