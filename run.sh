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
        CONTAINER_NAME="${2:-clauntainer}"
        echo "Stopping $CONTAINER_NAME..."
        docker stop "$CONTAINER_NAME" && docker rm "$CONTAINER_NAME"
        echo "Container stopped and removed"
        exit 0
        ;;
    logs)
        CONTAINER_NAME="${2:-clauntainer}"
        echo "Showing logs for $CONTAINER_NAME (Ctrl+C to exit)..."
        docker logs -f "$CONTAINER_NAME"
        exit 0
        ;;
    restart)
        CONTAINER_NAME="${2:-clauntainer}"
        echo "Restarting $CONTAINER_NAME..."
        docker restart "$CONTAINER_NAME"
        echo "Container restarted"
        exit 0
        ;;
    ssh)
        CONTAINER_NAME="${2:-clauntainer}"
        # Get the actual port
        SSH_PORT=$(docker port "$CONTAINER_NAME" 22 2>/dev/null | cut -d: -f2)
        if [ -z "$SSH_PORT" ]; then
            echo "ERROR: Container $CONTAINER_NAME is not running or port not found"
            echo "Run 'clauntainer list' to see running containers"
            exit 1
        fi
        # Connect with optional tmux attachment
        if [ "${3:-}" = "-t" ] || [ "${3:-}" = "--tmux" ]; then
            echo "Connecting to $CONTAINER_NAME on port $SSH_PORT (attaching to tmux)..."
            exec env TERM=xterm-256color ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_clauntainer node@localhost -t tmux attach -t claude
        else
            echo "Connecting to $CONTAINER_NAME on port $SSH_PORT..."
            exec env TERM=xterm-256color ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_clauntainer node@localhost
        fi
        ;;
    list|ps)
        echo "Running Clauntainers:"
        docker ps --filter "ancestor=clauntainer:latest" --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}\t{{.CreatedAt}}"
        exit 0
        ;;
esac

# Function to find an available port
find_available_port() {
    local port
    # Try random ports between 10000-60000
    for i in {1..10}; do
        port=$((RANDOM % 50000 + 10000))
        if ! ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
            echo "$port"
            return 0
        fi
    done
    # Fallback: let system assign
    echo "0"
}

# Default values
SSH_PORT="${SSH_PORT:-}"
REPO_URL="${REPO_URL:-}"
REPO_DIR="${REPO_DIR:-/workspace/repo}"
INIT_FIREWALL="${INIT_FIREWALL:-false}"
START_CLAUDE="${START_CLAUDE:-true}"
SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-false}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519_clauntainer.pub}"
CLAUDE_CONFIG="${CLAUDE_CONFIG:-$HOME/.claude}"
WORKSPACE_DIR="${WORKSPACE_DIR:-}"  # No default - only mount if explicitly specified
CONTAINER_NAME="${CONTAINER_NAME:-}"
AUTO_SSH="${AUTO_SSH:-true}"  # Automatically SSH into tmux session after starting

# Parse command line arguments
show_usage() {
    cat <<EOF
Clauntainer - Secure Claude Code Container Launcher

Usage:
    clauntainer [OPTIONS]              Start a new container
    clauntainer ssh [NAME] [-t]        SSH into a container (-t for tmux)
    clauntainer stop [NAME]            Stop and remove a container
    clauntainer logs [NAME]            View container logs
    clauntainer restart [NAME]         Restart a container
    clauntainer list                   List all running clauntainers

Options:
    -r, --repo URL          Repository URL to clone
    -d, --dir PATH          Directory to clone into (default: /workspace/repo)
    -p, --port PORT         SSH port to expose (default: auto-assigned)
    -n, --name NAME         Container name (default: auto-generated from repo)
    -f, --firewall          Initialize firewall on startup
    -c, --claude            Auto-start Claude Code in tmux
    -s, --skip-perms        Use --dangerously-skip-permissions flag
    -k, --key PATH          Path to SSH public key (default: ~/.ssh/id_ed25519_clauntainer.pub)
    -w, --workspace PATH    Path to mount as workspace (optional, default: container-internal only)
    --no-ssh                Don't automatically SSH into the container (default: auto-connect)
    -h, --help              Show this help message

Environment Variables:
    CLAUDE_CODE_VERSION    Version of Claude Code to install (default: latest)
    TZ                     Timezone (default: UTC)

Examples:
    # From any git repo - auto-assigns port and name
    cd ~/code/myproject && clauntainer -c

    # Run multiple containers in parallel (auto-assigns ports)
    cd ~/project1 && clauntainer -c
    cd ~/project2 && clauntainer -c

    # SSH into a container
    clauntainer ssh clauntainer-myproject

    # SSH and attach to tmux/Claude Code session
    clauntainer ssh clauntainer-myproject -t

    # List all running containers
    clauntainer list

    # Stop a specific container
    clauntainer stop clauntainer-myproject

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
        -n|--name)
            CONTAINER_NAME="$2"
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
        --no-ssh)
            AUTO_SSH="false"
            shift
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
        echo "Note: Will clone into container workspace (not mount local directory)"
    else
        echo "WARNING: Current directory is a git repo but has no 'origin' remote"
        echo "Please specify a repository URL with -r or add an origin remote"
        exit 1
    fi
fi

# Extract git user configuration from current repo or global config
GIT_USER_NAME=""
GIT_USER_EMAIL=""
if [ -d "$USER_DIR/.git" ]; then
    # Try repo-specific config first, then fall back to global
    GIT_USER_NAME=$(cd "$USER_DIR" && git config user.name 2>/dev/null || echo "")
    GIT_USER_EMAIL=$(cd "$USER_DIR" && git config user.email 2>/dev/null || echo "")
else
    # Use global git config if not in a repo
    GIT_USER_NAME=$(git config --global user.name 2>/dev/null || echo "")
    GIT_USER_EMAIL=$(git config --global user.email 2>/dev/null || echo "")
fi

if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
    echo "Using git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"
fi

# Validate SSH key exists
if [ ! -f "$SSH_PUBLIC_KEY" ]; then
    echo "ERROR: SSH public key not found at: $SSH_PUBLIC_KEY"
    echo "Generate one with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

# Convert WORKSPACE_DIR to absolute path if it's relative (only if specified)
if [ -n "$WORKSPACE_DIR" ]; then
    if [[ "$WORKSPACE_DIR" != /* ]]; then
        WORKSPACE_DIR="$USER_DIR/$WORKSPACE_DIR"
    fi
    # Create workspace directory if it doesn't exist
    mkdir -p "$WORKSPACE_DIR"
fi

# Auto-assign SSH port if not specified
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(find_available_port)
    echo "Auto-assigned SSH port: $SSH_PORT"
fi

# Generate container name from repo if not specified
if [ -z "$CONTAINER_NAME" ]; then
    if [ -n "$REPO_URL" ]; then
        # Extract repo name from URL
        REPO_NAME=$(basename "$REPO_URL" .git | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        CONTAINER_NAME="clauntainer-${REPO_NAME}"
    else
        # Use current directory name
        DIR_NAME=$(basename "$USER_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        CONTAINER_NAME="clauntainer-${DIR_NAME}"
    fi
    echo "Auto-generated container name: $CONTAINER_NAME"
fi

echo "Starting Clauntainer..."
echo "  Container Name: $CONTAINER_NAME"
echo "  SSH Port: $SSH_PORT"
echo "  SSH Key: $SSH_PUBLIC_KEY"
if [ -n "$WORKSPACE_DIR" ]; then
    echo "  Workspace (mounted): $WORKSPACE_DIR"
fi
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

# Build image if it doesn't exist
if ! docker image inspect clauntainer:latest >/dev/null 2>&1; then
    echo "Building clauntainer image..."
    cd "$SCRIPT_DIR" || {
        echo "ERROR: Failed to change to script directory: $SCRIPT_DIR"
        exit 1
    }
    docker build -t clauntainer:latest \
        --build-arg CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}" \
        --build-arg TZ="${TZ:-UTC}" \
        .
fi

# Prepare GitHub authentication for git clone
if [ -n "$REPO_URL" ]; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        echo "Using GITHUB_TOKEN for authentication"
    else
        echo "No GITHUB_TOKEN found. For private repos, set: export GITHUB_TOKEN=ghp_..."
    fi
fi

# Export environment variables for docker compose
export CONTAINER_NAME
export SSH_PORT
export SSH_PUBLIC_KEY
export CLAUDE_CONFIG
export GIT_CONFIG="$HOME/.gitconfig"
export GNUPG_DIR="$HOME/.gnupg"
export CLAUDE_JSON="$HOME/.claude.json"
export WORKSPACE_DIR  # Will be empty or set by user
export REPO_URL
export REPO_DIR
export INIT_FIREWALL
export START_CLAUDE
export SKIP_PERMISSIONS
export GITHUB_TOKEN
export GIT_USER_NAME
export GIT_USER_EMAIL

# Generate compose file on-the-fly
COMPOSE_FILE="/tmp/clauntainer-$CONTAINER_NAME.yaml"
cat > "$COMPOSE_FILE" <<'EOF'
services:
  clauntainer:
    image: clauntainer:latest
    container_name: ${CONTAINER_NAME:-clauntainer}
    hostname: ${CONTAINER_NAME:-clauntainer}
    ports:
      - "${SSH_PORT:-2222}:22"
    environment:
      - REPO_URL=${REPO_URL:-}
      - REPO_DIR=${REPO_DIR:-/workspace/repo}
      - INIT_FIREWALL=${INIT_FIREWALL:-false}
      - START_CLAUDE=${START_CLAUDE:-true}
      - SKIP_PERMISSIONS=${SKIP_PERMISSIONS:-false}
      - GITHUB_TOKEN=${GITHUB_TOKEN:-}
      - GIT_USER_NAME=${GIT_USER_NAME:-}
      - GIT_USER_EMAIL=${GIT_USER_EMAIL:-}
    volumes:
      - ${SSH_PUBLIC_KEY:-~/.ssh/id_ed25519_clauntainer.pub}:/tmp/host_ssh_key.pub:ro
      - ${CLAUDE_CONFIG:-~/.claude}:/tmp/host_claude:ro
      - ${CLAUDE_JSON:-~/.claude.json}:/tmp/host_claude.json:ro
      - ${GIT_CONFIG:-~/.gitconfig}:/home/node/.gitconfig:ro
      - ${GNUPG_DIR:-~/.gnupg}:/home/node/.gnupg:ro
      - ${WORKSPACE_DIR:-workspace}:/workspace
      - command-history:/commandhistory
    cap_add:
      - NET_ADMIN
    stdin_open: true
    tty: true
    restart: unless-stopped

volumes:
  command-history:
  workspace:
EOF

# Use docker compose to start the container
docker compose -p "clauntainer-$CONTAINER_NAME" -f "$COMPOSE_FILE" up -d

# Clean up temp compose file
rm -f "$COMPOSE_FILE"

# Get the actual assigned port (in case Docker reassigned it)
ACTUAL_PORT=$(docker port "$CONTAINER_NAME" 22 | cut -d: -f2)
if [ -n "$ACTUAL_PORT" ]; then
    SSH_PORT="$ACTUAL_PORT"
fi

echo ""
echo "Container started successfully!"
echo ""
echo "Connect via SSH:"
echo "  ssh -p $SSH_PORT -i ~/.ssh/id_ed25519_clauntainer node@localhost"
echo ""
if [ "$START_CLAUDE" = "true" ]; then
    echo "Claude Code is running in tmux session 'claude'"
    echo "Attach to it:"
    echo "  TERM=xterm-256color ssh -p $SSH_PORT -i ~/.ssh/id_ed25519_clauntainer node@localhost -t tmux attach -t claude"
    echo ""
fi
echo "Emacs TRAMP connection string:"
echo "  /ssh:node@localhost#$SSH_PORT:$REPO_DIR"
echo ""
echo "View logs:"
echo "  clauntainer logs $CONTAINER_NAME"
echo ""
echo "Stop container:"
echo "  clauntainer stop $CONTAINER_NAME"
echo ""
echo "List all running containers:"
echo "  clauntainer list"
echo ""

# Auto-SSH into tmux session if enabled
if [ "$AUTO_SSH" = "true" ] && [ "$START_CLAUDE" = "true" ]; then
    echo "Connecting to tmux session..."
    sleep 2  # Give container a moment to fully start
    exec env TERM=xterm-256color ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_clauntainer node@localhost -t tmux attach -t claude
fi
