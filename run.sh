#!/bin/bash

# Den - Secure Claude Code Container Launcher
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
        CONTAINER_NAME="${2:-den}"
        echo "Stopping $CONTAINER_NAME..."
        docker stop "$CONTAINER_NAME" && docker rm "$CONTAINER_NAME"
        echo "Container stopped and removed"
        exit 0
        ;;
    logs)
        CONTAINER_NAME="${2:-den}"
        echo "Showing logs for $CONTAINER_NAME (Ctrl+C to exit)..."
        docker logs -f "$CONTAINER_NAME"
        exit 0
        ;;
    restart)
        CONTAINER_NAME="${2:-den}"
        echo "Restarting $CONTAINER_NAME..."
        docker restart "$CONTAINER_NAME"
        echo "Container restarted"
        exit 0
        ;;
    ssh)
        CONTAINER_NAME="${2:-den}"
        # Get the actual port
        SSH_PORT=$(docker port "$CONTAINER_NAME" 22 2>/dev/null | cut -d: -f2)
        if [ -z "$SSH_PORT" ]; then
            echo "ERROR: Container $CONTAINER_NAME is not running or port not found"
            echo "Run 'den list' to see running containers"
            exit 1
        fi
        # Connect with optional tmux attachment
        if [ "${3:-}" = "-t" ] || [ "${3:-}" = "--tmux" ]; then
            echo "Connecting to $CONTAINER_NAME on port $SSH_PORT (attaching to tmux)..."
            exec env TERM=xterm-256color ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_den node@localhost -t 'tmux -u attach -t pi 2>/dev/null || tmux -u attach -t claude'
        else
            echo "Connecting to $CONTAINER_NAME on port $SSH_PORT..."
            exec env TERM=xterm-256color ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_den node@localhost
        fi
        ;;
    list|ps)
        echo "Running Dens:"
        docker ps --filter "ancestor=den:latest" --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}\t{{.CreatedAt}}"
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
START_PI="${START_PI:-false}"
PI_EXTRA_ARGS="${PI_EXTRA_ARGS:-}"
SKIP_PERMISSIONS="${SKIP_PERMISSIONS:-false}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519_den.pub}"
CLAUDE_CONFIG="${CLAUDE_CONFIG:-$HOME/.claude}"
PI_CONFIG="${PI_CONFIG:-${PI_CODING_AGENT_DIR:-$HOME/.pi}}"
WORKSPACE_DIR="${WORKSPACE_DIR:-}"  # No default - only mount if explicitly specified
CONTAINER_NAME="${CONTAINER_NAME:-}"
AUTO_SSH="${AUTO_SSH:-true}"  # Automatically SSH into tmux session after starting
USE_WORKTREE="${USE_WORKTREE:-false}"  # Create and mount a git worktree
WORKTREE_BRANCH="${WORKTREE_BRANCH:-}"  # Optional branch name for worktree
FLAVOR="${FLAVOR:-}"  # Dockerfile flavor (e.g., flutter, python)

# Parse command line arguments
show_usage() {
    cat <<EOF
Den - Secure Claude Code Container Launcher

Usage:
    den [OPTIONS]              Start a new container
    den ssh [NAME] [-t]        SSH into a container (-t for tmux)
    den stop [NAME]            Stop and remove a container
    den logs [NAME]            View container logs
    den restart [NAME]         Restart a container
    den list                   List all running dens

Options:
    -r, --repo URL          Repository URL to clone
    -d, --dir PATH          Directory to clone into (default: /workspace/repo)
    -p, --port PORT         SSH port to expose (default: auto-assigned)
    -n, --name NAME         Container name (default: auto-generated from repo)
    -f, --firewall          Initialize firewall on startup
    -c, --claude            Auto-start Claude Code in tmux (default)
    -P, --pi                Auto-start pi.dev coding agent in tmux (mutex with -c)
    -s, --skip-perms        Use --dangerously-skip-permissions flag (Claude only)
    -k, --key PATH          Path to SSH public key (default: ~/.ssh/id_ed25519_den.pub)
    -w, --workspace PATH    Path to mount as workspace (optional, default: container-internal only)
    -W, --worktree [NAME]   Create git worktree in .worktrees/ and mount it (optionally specify branch/name)
    -F, --flavor NAME       Dockerfile flavor to use (e.g., flutter, python) - auto-detected by default
    --no-ssh                Don't automatically SSH into the container (default: auto-connect)
    -h, --help              Show this help message

Pass-through:
    Anything after `--` is forwarded verbatim to the agent (claude or pi). Example:
        den -P -- -e ./my-extension.ts -e npm:@foo/pi-tools
    Note: extension paths are resolved inside the container (e.g. /workspace/...).

Environment Variables:
    CLAUDE_CODE_VERSION    Version of Claude Code to install (default: latest)
    TZ                     Timezone (default: UTC)

Examples:
    # From any git repo - auto-assigns port and name
    cd ~/code/myproject && den -c

    # Use git worktree (creates .worktrees/<name> and mounts it)
    cd ~/code/myproject && den -W -c

    # Use git worktree with specific branch name
    cd ~/code/myproject && den -W feature-branch -c

    # Auto-detect and use appropriate Dockerfile flavor (e.g., Flutter)
    cd ~/flutter-project && den -c

    # Or explicitly specify a flavor
    cd ~/flutter-project && den -c -F flutter

    # Run multiple containers in parallel (auto-assigns ports)
    cd ~/project1 && den -c
    cd ~/project2 && den -c

    # Run pi.dev coding agent instead of Claude Code
    cd ~/code/myproject && den -P

    # Run pi with extensions (paths resolve inside container)
    cd ~/code/myproject && den -P -- -e npm:@foo/pi-tools -e ./tools/my-ext.ts

    # SSH into a container
    den ssh den-myproject

    # SSH and attach to tmux/Claude Code session
    den ssh den-myproject -t

    # List all running containers
    den list

    # Stop a specific container
    den stop den-myproject

After starting, connect via:
    ssh -p $SSH_PORT node@localhost

    # Or with tmux
    ssh -p $SSH_PORT node@localhost -t tmux -u attach -t claude

    # Or with Emacs TRAMP
    /ssh:node@localhost#$SSH_PORT:/workspace/repo

EOF
}

# Function to auto-detect project flavor
detect_flavor() {
    local dir="$1"

    # Flutter/Dart - check for pubspec.yaml with flutter dependency
    if [ -f "$dir/pubspec.yaml" ]; then
        if grep -q "flutter:" "$dir/pubspec.yaml" 2>/dev/null; then
            echo "flutter"
            return
        fi
    fi

    # Go - check for go.mod
    if [ -f "$dir/go.mod" ]; then
        echo "go"
        return
    fi

    # Rust - check for Cargo.toml
    if [ -f "$dir/Cargo.toml" ]; then
        echo "rust"
        return
    fi

    # Add more detections here as new flavors are added
    # Python - pyproject.toml, setup.py, requirements.txt
    # if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] || [ -f "$dir/requirements.txt" ]; then
    #     echo "python"
    #     return
    # fi

    # Default - no special flavor needed
    echo ""
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
            START_PI="false"
            shift
            ;;
        -P|--pi)
            START_PI="true"
            START_CLAUDE="false"
            shift
            ;;
        --)
            shift
            PI_EXTRA_ARGS="$*"
            break
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
        -W|--worktree)
            USE_WORKTREE="true"
            # Check if next argument is a branch/worktree name (not a flag)
            if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
                WORKTREE_BRANCH="$2"
                shift 2
            else
                shift
            fi
            ;;
        -F|--flavor)
            FLAVOR="$2"
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
# Skip auto-clone if workspace is being mounted (user wants their exact state)
# Skip in worktree mode too: it mounts a local worktree and needs no remote
if [ -z "$REPO_URL" ] && [ -z "$WORKSPACE_DIR" ] && [ "$USE_WORKTREE" != "true" ] && [ -d "$USER_DIR/.git" ]; then
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

# Create git worktree if requested
if [ "$USE_WORKTREE" = "true" ]; then
    if [ ! -d "$USER_DIR/.git" ]; then
        echo "ERROR: --worktree requires being run from a git repository"
        exit 1
    fi

    # Determine base branch for new branches (origin/main or origin/master)
    BASE_BRANCH=""
    if cd "$USER_DIR" && git rev-parse --verify origin/main >/dev/null 2>&1; then
        BASE_BRANCH="origin/main"
    elif cd "$USER_DIR" && git rev-parse --verify origin/master >/dev/null 2>&1; then
        BASE_BRANCH="origin/master"
    else
        echo "WARNING: Could not find origin/main or origin/master, using HEAD as base"
        BASE_BRANCH="HEAD"
    fi

    # Determine branch to use for worktree
    if [ -n "${WORKTREE_BRANCH:-}" ]; then
        # User specified a branch name
        TARGET_BRANCH="$WORKTREE_BRANCH"
        WORKTREE_NAME="$WORKTREE_BRANCH"
    else
        # Generate a new branch name with timestamp
        CURRENT_BRANCH=$(cd "$USER_DIR" && git rev-parse --abbrev-ref HEAD)
        if [ -n "$CONTAINER_NAME" ]; then
            TARGET_BRANCH="$CONTAINER_NAME"
            WORKTREE_NAME="$CONTAINER_NAME"
        else
            # Use a generated name based on current branch or timestamp
            if [ "$CURRENT_BRANCH" != "HEAD" ]; then
                TARGET_BRANCH="$CURRENT_BRANCH-$(date +%s)"
            else
                TARGET_BRANCH="worktree-$(date +%s)"
            fi
            WORKTREE_NAME="$TARGET_BRANCH"
        fi
    fi

    echo "Creating git worktree: $TARGET_BRANCH"

    # Create .worktrees directory
    WORKTREES_DIR="$USER_DIR/.worktrees"
    mkdir -p "$WORKTREES_DIR"

    WORKTREE_PATH="$WORKTREES_DIR/$WORKTREE_NAME"

    # Check if worktree already exists
    if [ -d "$WORKTREE_PATH" ]; then
        echo "Worktree already exists at: $WORKTREE_PATH"
        echo "Reusing existing worktree"
    else
        echo "Creating worktree at: $WORKTREE_PATH"

        # Check if branch exists
        if cd "$USER_DIR" && git rev-parse --verify "$TARGET_BRANCH" >/dev/null 2>&1; then
            # Branch exists, create worktree from it
            echo "Branch '$TARGET_BRANCH' exists, checking it out in worktree"
            cd "$USER_DIR" && git worktree add "$WORKTREE_PATH" "$TARGET_BRANCH" || {
                echo "ERROR: Failed to create git worktree"
                exit 1
            }
        else
            # Branch doesn't exist, create new branch and worktree from base branch
            echo "Branch '$TARGET_BRANCH' doesn't exist, creating new branch from $BASE_BRANCH"
            cd "$USER_DIR" && git worktree add -b "$TARGET_BRANCH" "$WORKTREE_PATH" "$BASE_BRANCH" || {
                echo "ERROR: Failed to create git worktree with new branch"
                exit 1
            }
        fi
    fi

    # Set WORKSPACE_DIR to the worktree path
    WORKSPACE_DIR="$WORKTREE_PATH"

    # Store the parent git directory path for mounting
    PARENT_GIT_DIR="$USER_DIR/.git"

    # Clear REPO_URL since we're mounting local workspace, not cloning
    REPO_URL=""

    # Set REPO_DIR to /workspace since we're mounting the worktree directly there
    REPO_DIR="/workspace"

    echo "Git worktree mounted to container workspace"
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
        CONTAINER_NAME="den-${REPO_NAME}"
    else
        # Use current directory name
        DIR_NAME=$(basename "$USER_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
        CONTAINER_NAME="den-${DIR_NAME}"
    fi
    echo "Auto-generated container name: $CONTAINER_NAME"
fi

# Auto-detect flavor if not explicitly set
if [ -z "$FLAVOR" ]; then
    DETECTED_FLAVOR=$(detect_flavor "$USER_DIR")
    if [ -n "$DETECTED_FLAVOR" ]; then
        FLAVOR="$DETECTED_FLAVOR"
        echo "Auto-detected project type: $FLAVOR"
    fi
fi

echo "Starting Den..."
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
if [ -n "$FLAVOR" ]; then
    echo "  Dockerfile Flavor: $FLAVOR"
fi
echo "  Firewall: $INIT_FIREWALL"
echo "  Auto-start Claude: $START_CLAUDE"
echo "  Auto-start Pi: $START_PI"
if [ "$START_CLAUDE" = "true" ]; then
    echo "  Skip Permissions: $SKIP_PERMISSIONS"
fi
if [ "$START_PI" = "true" ] && [ -n "$PI_EXTRA_ARGS" ]; then
    echo "  Pi args: $PI_EXTRA_ARGS"
fi
echo ""

# Determine Dockerfile and image tag based on flavor
if [ -n "$FLAVOR" ]; then
    DOCKERFILE="Dockerfile.$FLAVOR"
    IMAGE_TAG="den:$FLAVOR"
else
    DOCKERFILE="Dockerfile"
    IMAGE_TAG="den:latest"
fi

# Build image if it doesn't exist
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Building $IMAGE_TAG image..."
    cd "$SCRIPT_DIR" || {
        echo "ERROR: Failed to change to script directory: $SCRIPT_DIR"
        exit 1
    }

    # Check if Dockerfile exists
    if [ ! -f "$DOCKERFILE" ]; then
        echo "ERROR: $DOCKERFILE not found in $SCRIPT_DIR"
        exit 1
    fi

    docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" \
        --build-arg CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}" \
        --build-arg TZ="${TZ:-UTC}" \
        --build-arg HOST_UID="$(id -u)" \
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
export GIT_CREDENTIALS="$HOME/.git-credentials"
export SSH_DIR="$HOME/.ssh"
export GNUPG_DIR="$HOME/.gnupg"
export CLAUDE_JSON="$HOME/.claude.json"
export HOST_HOME="$HOME"  # Symlinked to /home/node in container so host-absolute config paths resolve
export WORKSPACE_DIR  # Will be empty or set by user
export PARENT_GIT_DIR  # Will be set if using worktree
export REPO_URL
export REPO_DIR
export INIT_FIREWALL
export START_CLAUDE
export START_PI
export PI_EXTRA_ARGS
export PI_CONFIG
export SKIP_PERMISSIONS
export GITHUB_TOKEN
export GIT_USER_NAME
export GIT_USER_EMAIL
export IMAGE_TAG  # Image tag to use (includes flavor)

# Generate compose file on-the-fly
COMPOSE_FILE="/tmp/den-$CONTAINER_NAME.yaml"
cat > "$COMPOSE_FILE" <<'EOF'
services:
  den:
    image: ${IMAGE_TAG:-den:latest}
    container_name: ${CONTAINER_NAME:-den}
    hostname: ${CONTAINER_NAME:-den}
    ports:
      - "${SSH_PORT:-2222}:22"
    environment:
      - REPO_URL=${REPO_URL:-}
      - REPO_DIR=${REPO_DIR:-/workspace/repo}
      - INIT_FIREWALL=${INIT_FIREWALL:-false}
      - START_CLAUDE=${START_CLAUDE:-true}
      - START_PI=${START_PI:-false}
      - PI_EXTRA_ARGS=${PI_EXTRA_ARGS:-}
      - SKIP_PERMISSIONS=${SKIP_PERMISSIONS:-false}
      - GITHUB_TOKEN=${GITHUB_TOKEN:-}
      - GIT_USER_NAME=${GIT_USER_NAME:-}
      - GIT_USER_EMAIL=${GIT_USER_EMAIL:-}
      - HOST_HOME=${HOST_HOME:-}
    volumes:
      - ${SSH_PUBLIC_KEY:-~/.ssh/id_ed25519_den.pub}:/tmp/host_ssh_key.pub:ro
      - ${CLAUDE_CONFIG:-~/.claude}:/tmp/host_claude:ro
      - ${CLAUDE_JSON:-~/.claude.json}:/tmp/host_claude.json:ro
      - ${GIT_CONFIG:-~/.gitconfig}:/tmp/host_gitconfig:ro
      - ${GNUPG_DIR:-~/.gnupg}:/home/node/.gnupg:ro
      - ${WORKSPACE_DIR:-workspace}:/workspace
      - command-history:/commandhistory
      - claude-plugins:/home/node/.claude/plugins
    cap_add:
      - NET_ADMIN
    stdin_open: true
    tty: true
    restart: unless-stopped

volumes:
  command-history:
  workspace:
  claude-plugins:
EOF

# Add conditional mounts for git authentication
# Mount git-credentials if it exists (for HTTPS push/pull)
if [ -f "$HOME/.git-credentials" ]; then
    echo "Mounting ~/.git-credentials for HTTPS git authentication"
    sed -i '/^    cap_add:/i\      - '"$HOME/.git-credentials"':/home/node/.git-credentials:ro' "$COMPOSE_FILE"
fi

# Mount SSH directory if it exists (for SSH-based git operations)
# Exclude the den-specific public key to avoid conflicts
if [ -d "$HOME/.ssh" ]; then
    echo "Mounting ~/.ssh directory for SSH-based git operations"
    sed -i '/^    cap_add:/i\      - '"$HOME/.ssh"':/home/node/.ssh-host:ro' "$COMPOSE_FILE"
fi

# Mount pi.dev config directory if it exists (entrypoint copies it to /home/node/.pi)
if [ -d "$PI_CONFIG" ]; then
    echo "Mounting $PI_CONFIG for pi.dev coding agent"
    sed -i '/^    cap_add:/i\      - '"$PI_CONFIG"':/tmp/host_pi:ro' "$COMPOSE_FILE"
fi

# Mount personal agents/skills directory if it exists (entrypoint copies it to /home/node/.agents).
# Claude skill symlinks under ~/.claude/skills point into this directory.
if [ -d "$HOME/.agents" ]; then
    echo "Mounting ~/.agents for personal skills"
    sed -i '/^    cap_add:/i\      - '"$HOME/.agents"':/tmp/host_agents:ro' "$COMPOSE_FILE"
fi

# Mount host sccache cache directory for Rust flavor (read-write, shared with host).
# UID match is handled by HOST_UID build arg, so files written from container
# are owned by the same user on the host.
if [ "$FLAVOR" = "rust" ]; then
    HOST_SCCACHE_DIR="${SCCACHE_DIR:-$HOME/.cache/sccache}"
    mkdir -p "$HOST_SCCACHE_DIR"
    echo "Mounting $HOST_SCCACHE_DIR -> /home/node/.cache/sccache (rw) for sccache reuse"
    sed -i '/^    cap_add:/i\      - '"$HOST_SCCACHE_DIR"':/home/node/.cache/sccache:rw' "$COMPOSE_FILE"
fi

# Add parent .git directory mount for worktrees
if [ -n "${PARENT_GIT_DIR:-}" ]; then
    # Mount the parent .git directory at the same absolute path as on the host
    # This is needed because the worktree's .git file contains an absolute path reference
    # Mount as read-write to allow commits and other git operations
    sed -i '/^    cap_add:/i\      - '"${PARENT_GIT_DIR}"':'"${PARENT_GIT_DIR}"'' "$COMPOSE_FILE"
fi

# Use docker compose to start the container
docker compose -p "den-$CONTAINER_NAME" -f "$COMPOSE_FILE" up -d

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
echo "  ssh -p $SSH_PORT -i ~/.ssh/id_ed25519_den node@localhost"
echo ""
if [ "$START_CLAUDE" = "true" ]; then
    echo "Claude Code is running in tmux session 'claude'"
    echo "Attach to it:"
    echo "  TERM=xterm-256color ssh -p $SSH_PORT -i ~/.ssh/id_ed25519_den node@localhost -t tmux -u attach -t claude"
    echo ""
fi
if [ "$START_PI" = "true" ]; then
    echo "pi.dev agent is running in tmux session 'pi'"
    echo "Attach to it:"
    echo "  TERM=xterm-256color ssh -p $SSH_PORT -i ~/.ssh/id_ed25519_den node@localhost -t tmux -u attach -t pi"
    echo ""
fi
echo "Emacs TRAMP connection string:"
echo "  /ssh:node@localhost#$SSH_PORT:$REPO_DIR"
echo ""
echo "View logs:"
echo "  den logs $CONTAINER_NAME"
echo ""
echo "Stop container:"
echo "  den stop $CONTAINER_NAME"
echo ""
echo "List all running containers:"
echo "  den list"
echo ""

# Determine which tmux session to attach to (pi takes precedence when both set)
if [ "$START_PI" = "true" ]; then
    TMUX_SESSION="pi"
else
    TMUX_SESSION="claude"
fi

# Auto-SSH into tmux session if enabled
if [ "$AUTO_SSH" = "true" ] && { [ "$START_CLAUDE" = "true" ] || [ "$START_PI" = "true" ]; }; then
    echo "Waiting for SSH to be ready..."

    # Wait for SSH to be available (max 30 seconds)
    MAX_RETRIES=30
    RETRY_COUNT=0
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_den \
               -o ConnectTimeout=1 \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o LogLevel=ERROR \
               node@localhost "exit 0" 2>/dev/null; then
            echo "SSH is ready!"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 1
    done

    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "WARNING: SSH didn't become ready in time. You can connect manually with:"
        echo "  ssh -p $SSH_PORT -i ~/.ssh/id_ed25519_den node@localhost -t tmux -u attach -t $TMUX_SESSION"
    else
        echo "Connecting to tmux session '$TMUX_SESSION'..."
        exec env TERM=xterm-256color ssh -p "$SSH_PORT" -i ~/.ssh/id_ed25519_den node@localhost -t tmux -u attach -t "$TMUX_SESSION"
    fi
fi
