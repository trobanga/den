#!/bin/bash

# Clauntainer - Secure Claude Code Container Launcher
# Usage: ./run.sh [OPTIONS]

set -euo pipefail

# Save the directory where the user invoked this script
USER_DIR="$(pwd)"

# Detect the directory where this script is located (resolve symlinks)
SCRIPT_PATH="${BASH_SOURCE[0]}"
# Follow symlinks to find the real script location
while [ -L "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ $SCRIPT_PATH != /* ]] && SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"

# Check for subcommands first
case "${1:-}" in
    stop)
        echo "Stopping Clauntainer..."
        cd "$SCRIPT_DIR"
        docker compose down
        echo "Container stopped and removed"
        exit 0
        ;;
    logs)
        echo "Showing Clauntainer logs (Ctrl+C to exit)..."
        cd "$SCRIPT_DIR"
        docker compose logs -f
        exit 0
        ;;
    restart)
        echo "Restarting Clauntainer..."
        cd "$SCRIPT_DIR"
        docker compose restart
        echo "Container restarted"
        exit 0
        ;;
esac

# Default values
SSH_PORT="${SSH_PORT:-2222}"
REPO_URL="${REPO_URL:-}"
REPO_DIR="${REPO_DIR:-/workspace/repo}"
INIT_FIREWALL="${INIT_FIREWALL:-false}"
START_CLAUDE="${START_CLAUDE:-true}"
SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-false}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519_clauntainer.pub}"
CLAUDE_CONFIG="${CLAUDE_CONFIG:-$HOME/.claude}"
WORKSPACE_DIR="${WORKSPACE_DIR:-./workspace}"

# Parse command line arguments
show_usage() {
    cat <<EOF
Clauntainer - Secure Claude Code Container Launcher

Usage:
    clauntainer [OPTIONS]              Start the container
    clauntainer stop                   Stop and remove the container
    clauntainer logs                   View container logs
    clauntainer restart                Restart the container

Options:
    -r, --repo URL          Repository URL to clone
    -d, --dir PATH         Directory to clone into (default: /workspace/repo)
    -p, --port PORT        SSH port to expose (default: 2222)
    -f, --firewall         Initialize firewall on startup
    -c, --claude           Auto-start Claude Code in tmux
    -s, --skip-perms       Use --dangerously-skip-permissions flag
    -k, --key PATH         Path to SSH public key (default: ~/.ssh/id_rsa.pub)
    -w, --workspace PATH   Path to mount as workspace (default: ./workspace)
    -h, --help             Show this help message

Environment Variables:
    CLAUDE_CODE_VERSION    Version of Claude Code to install (default: latest)
    TZ                     Timezone (default: UTC)

Examples:
    # Basic usage - just start container
    run.sh

    # From any git repo - auto-detects the repo
    cd ~/code/myproject && clauntainer -c

    # Clone a specific repo and start Claude Code
    clauntainer -r https://github.com/user/repo -c

    # Clone repo with firewall and skip permissions
    clauntainer -r https://github.com/user/repo -f -c -s

    # Custom SSH port and key
    clauntainer -p 3333 -k ~/.ssh/custom_key.pub

After starting, connect via:
    ssh -p $SSH_PORT node@localhost

    # Or with tmux
    ssh -p $SSH_PORT node@localhost -t tmux attach -t claude

    # Or with Emacs TRAMP
    /ssh:node@localhost#$SSH_PORT:/workspace/repo

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--repo)
            REPO_URL="$2"
            shift 2
            ;;
        -d|--dir)
            REPO_DIR="$2"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -f|--firewall)
            INIT_FIREWALL="true"
            shift
            ;;
        -c|--claude)
            START_CLAUDE="true"
            shift
            ;;
        -s|--skip-perms)
            SKIP_PERMISSIONS="true"
            shift
            ;;
        -k|--key)
            SSH_PUBLIC_KEY="$2"
            shift 2
            ;;
        -w|--workspace)
            WORKSPACE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# If no REPO_URL provided, check if current directory is a git repo
if [ -z "$REPO_URL" ] && [ -d "$USER_DIR/.git" ]; then
    echo "Detected git repository in current directory"
    REPO_URL=$(cd "$USER_DIR" && git remote get-url origin 2>/dev/null || echo "")
    if [ -n "$REPO_URL" ]; then
        echo "Using remote URL: $REPO_URL"
    else
        echo "WARNING: Current directory is a git repo but has no 'origin' remote"
        echo "Please specify a repository URL with -r or add an origin remote"
        exit 1
    fi
fi

# Validate SSH key exists
if [ ! -f "$SSH_PUBLIC_KEY" ]; then
    echo "ERROR: SSH public key not found at: $SSH_PUBLIC_KEY"
    echo "Generate one with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

# Convert WORKSPACE_DIR to absolute path if it's relative
if [[ "$WORKSPACE_DIR" != /* ]]; then
    WORKSPACE_DIR="$USER_DIR/$WORKSPACE_DIR"
fi

# Create workspace directory if it doesn't exist
mkdir -p "$WORKSPACE_DIR"

echo "Starting Clauntainer..."
echo "  SSH Port: $SSH_PORT"
echo "  SSH Key: $SSH_PUBLIC_KEY"
echo "  Workspace: $WORKSPACE_DIR"
if [ -n "$REPO_URL" ]; then
    echo "  Repository: $REPO_URL"
    echo "  Clone to: $REPO_DIR"
fi
echo "  Firewall: $INIT_FIREWALL"
echo "  Auto-start Claude: $START_CLAUDE"
if [ "$START_CLAUDE" = "true" ]; then
    echo "  Skip Permissions: $SKIP_PERMISSIONS"
fi
echo ""

# Export environment variables for docker compose
export SSH_PORT REPO_URL REPO_DIR INIT_FIREWALL START_CLAUDE SKIP_PERMISSIONS
export SSH_PUBLIC_KEY CLAUDE_CONFIG WORKSPACE_DIR

# Change to script directory and start container
cd "$SCRIPT_DIR" || {
    echo "ERROR: Failed to change to script directory: $SCRIPT_DIR"
    exit 1
}

# Verify compose file exists
if [ ! -f "compose.yaml" ]; then
    echo "ERROR: compose.yaml not found in $SCRIPT_DIR"
    echo "This usually means the script was copied instead of symlinked."
    echo "Please create a symlink: ln -s /home/trobanga/code/clauntainer/run.sh ~/bin/clauntainer"
    exit 1
fi

docker compose up -d --build

echo ""
echo "Container started successfully!"
echo ""
echo "Connect via SSH:"
echo "  ssh -p $SSH_PORT node@localhost"
echo ""
if [ "$START_CLAUDE" = "true" ]; then
    echo "Claude Code is running in tmux session 'claude'"
    echo "Attach to it:"
    echo "  ssh -p $SSH_PORT node@localhost -t tmux attach -t claude"
    echo ""
fi
echo "Emacs TRAMP connection string:"
echo "  /ssh:node@localhost#$SSH_PORT:$REPO_DIR"
echo ""
echo "View logs:"
echo "  docker compose logs -f"
echo ""
echo "Stop container:"
echo "  docker compose down"
