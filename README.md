# Clauntainer

A secure, isolated Docker container for running Claude Code with network restrictions and SSH access. Perfect for safely testing Claude Code on untrusted repositories or working in a sandboxed environment.

## Features

- 🔒 **Network isolation** with iptables-based whitelist firewall
- 🤖 **Claude Code** pre-installed and auto-starting in tmux
- 🔑 **SSH access** for remote development (tmux, Emacs TRAMP, etc.)
- 📦 **Automatic git cloning** from current directory or specified URL
- 🛡️ **Non-root user** with minimal sudo permissions
- 🔧 **Full development environment** (Node.js 20, zsh, git, gh, etc.)

## Prerequisites

- Docker with Compose v2
- SSH key pair (`~/.ssh/id_rsa.pub` or specify custom)
- Git (if using auto-detection)
- Claude Code API key configured in `~/.claude`

## Quick Start

### Option 1: Auto-detect current repository

```bash
cd /path/to/your/git/repo
./run.sh
```

This will:
1. Detect your current git repo's remote URL
2. Build and start the container
3. Clone the repo inside the container
4. Start Claude Code in a tmux session
5. Expose SSH on port 2222

### Option 2: Specify a repository

```bash
./run.sh -r https://github.com/user/repo
```

### Option 3: Just start a container (no repo)

```bash
./run.sh -r ""
```

## Connecting to the Container

### Via SSH

```bash
ssh -p 2222 node@localhost
```

### Attach to Claude Code in tmux

```bash
ssh -p 2222 node@localhost -t tmux attach -t claude
```

### Emacs TRAMP

```elisp
C-x C-f /ssh:node@localhost#2222:/workspace/repo
```

Then use `M-x shell` or `M-x eshell` and run `tmux attach -t claude`.

## Usage Examples

### Basic usage with firewall enabled

```bash
./run.sh -r https://github.com/suspicious/repo -f
```

### Custom SSH port and skip permissions

```bash
./run.sh -r https://github.com/user/repo -p 3333 -s
```

### Use custom SSH key

```bash
./run.sh -k ~/.ssh/custom_key.pub -r https://github.com/user/repo
```

### Stop and remove the container

```bash
docker compose down
```

### View container logs

```bash
docker compose logs -f
```

## Command-Line Options

| Flag | Long Form | Description | Default |
|------|-----------|-------------|---------|
| `-r` | `--repo` | Repository URL to clone | Auto-detect from current dir |
| `-d` | `--dir` | Directory to clone into | `/workspace/repo` |
| `-p` | `--port` | SSH port to expose | `2222` |
| `-f` | `--firewall` | Initialize firewall on startup | `false` |
| `-c` | `--claude` | Auto-start Claude Code (deprecated, now default) | `true` |
| `-s` | `--skip-perms` | Use `--dangerously-skip-permissions` | `false` |
| `-k` | `--key` | Path to SSH public key | `~/.ssh/id_rsa.pub` |
| `-w` | `--workspace` | Path to mount as workspace | `./workspace` |
| `-h` | `--help` | Show help message | - |

## Environment Variables

You can also configure the container via environment variables:

```bash
REPO_URL=https://github.com/user/repo \
START_CLAUDE=true \
SKIP_PERMISSIONS=true \
docker compose up -d --build
```

Available variables:
- `REPO_URL` - Git repository URL
- `REPO_DIR` - Target directory inside container (default: `/workspace/repo`)
- `INIT_FIREWALL` - Enable firewall (`true`/`false`, default: `false`)
- `START_CLAUDE` - Auto-start Claude Code (`true`/`false`, default: `true`)
- `SKIP_PERMISSIONS` - Use `--dangerously-skip-permissions` (`true`/`false`, default: `false`)
- `SSH_PORT` - External SSH port (default: `2222`)
- `CLAUDE_CODE_VERSION` - Version to install (default: `latest`)
- `TZ` - Timezone (default: `UTC`)

## Network Security

The optional firewall restricts outbound network access to a whitelist of approved destinations:

**Allowed domains:**
- GitHub (api.github.com, github.com, raw.githubusercontent.com)
- npm registry (registry.npmjs.org)
- Anthropic API (api.anthropic.com)
- Sentry and Statsig (for telemetry)
- VS Code marketplace

**Enable the firewall:**
```bash
./run.sh -f
```

**WHY:** This prevents Claude Code from accessing arbitrary internet resources when working with untrusted code. DNS and SSH remain functional, and the host network is accessible for Docker integration.

## Architecture

The container uses:
- **Base image:** Node.js 20 on Debian
- **User:** Non-root `node` user (UID 1000)
- **SSH:** OpenSSH with key-based auth only
- **Shell:** zsh with oh-my-zsh and powerlevel10k
- **Firewall:** iptables + ipset for IP-based whitelisting
- **Process manager:** tmux for persistent Claude Code sessions

Files:
- `Dockerfile` - Container image definition
- `compose.yaml` - Docker Compose configuration
- `entrypoint.sh` - Container startup script
- `init-firewall.sh` - Network security setup
- `run.sh` - User-facing launcher script

## Troubleshooting

### Can't connect via SSH

```bash
# Check if container is running
docker compose ps

# Check SSH service
docker compose exec clauntainer ps aux | grep sshd

# Verify your public key is mounted
docker compose exec clauntainer cat /home/node/.ssh/authorized_keys
```

### Claude Code isn't running

```bash
# Check tmux sessions
ssh -p 2222 node@localhost tmux ls

# View container logs
docker compose logs -f

# Restart the container
docker compose restart
```

### Firewall blocking required domains

Edit `init-firewall.sh` and add your domain to the whitelist loop (around line 67), then rebuild:

```bash
docker compose down
docker compose up -d --build
```

### Permission errors

If Claude Code shows permission errors, use the `-s` flag:

```bash
./run.sh -s
```

## Security Considerations

- The container runs as non-root (`node` user)
- SSH uses public key authentication only (no passwords)
- Root login is disabled
- Only the `node` user can SSH in
- The firewall (when enabled) uses default-deny policies
- The container requires `NET_ADMIN` capability for firewall management

## Development

To modify the container:

1. Edit `Dockerfile`, `entrypoint.sh`, or `init-firewall.sh`
2. Rebuild: `docker compose up -d --build`
3. Test your changes

To update Claude Code version:

```bash
CLAUDE_CODE_VERSION=0.1.23 docker compose up -d --build
```

## License

This project is provided as-is for educational and development purposes.

## Contributing

Issues and pull requests are welcome! Please ensure any changes maintain the security model.
