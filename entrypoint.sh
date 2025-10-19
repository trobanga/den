#!/bin/bash
set -euo pipefail

# Start SSH server (requires root)
sudo /usr/sbin/sshd

echo "SSH server started on port 22"

# Initialize firewall if requested
if [ "${INIT_FIREWALL:-false}" = "true" ]; then
    echo "Initializing firewall..."
    sudo /usr/local/bin/init-firewall.sh
    echo "Firewall initialized"
fi

# Clone repository if REPO_URL is provided
if [ -n "${REPO_URL:-}" ]; then
    REPO_DIR="${REPO_DIR:-/workspace/repo}"

    if [ -d "$REPO_DIR" ]; then
        echo "Directory $REPO_DIR already exists, skipping clone"
    else
        echo "Cloning repository $REPO_URL to $REPO_DIR..."
        git clone "$REPO_URL" "$REPO_DIR"
        echo "Repository cloned successfully"
    fi

    cd "$REPO_DIR"
else
    REPO_DIR="/workspace"
    cd "$REPO_DIR"
fi

# Start Claude Code if requested
if [ "${START_CLAUDE:-true}" = "true" ]; then
    echo "Starting Claude Code in tmux session 'claude'..."

    # Build claude command with optional skip-permissions flag
    CLAUDE_CMD="claude"
    if [ "${SKIP_PERMISSIONS:-false}" = "true" ]; then
        CLAUDE_CMD="$CLAUDE_CMD --dangerously-skip-permissions"
    fi

    # Start Claude in a detached tmux session
    tmux new-session -d -s claude "cd $REPO_DIR && $CLAUDE_CMD"
    echo "Claude Code started in tmux session 'claude'"
    echo "Connect with: tmux attach -t claude"
fi

echo "Container ready! Connect via SSH on port 22"
echo "Working directory: $REPO_DIR"

# Keep container running by tailing a log or using wait
tail -f /dev/null
