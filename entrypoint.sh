#!/bin/bash
set -euo pipefail

# Start rsyslog for SSH logging
sudo rsyslogd

# Generate host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    echo "Generating SSH host keys..."
    sudo ssh-keygen -A
fi

# Set up SSH authorized_keys from mounted host key
if [ -f /tmp/host_ssh_key.pub ]; then
    mkdir -p /home/node/.ssh
    cp /tmp/host_ssh_key.pub /home/node/.ssh/authorized_keys
    chmod 700 /home/node/.ssh
    chmod 600 /home/node/.ssh/authorized_keys
    echo "SSH public key installed"
fi

# Configure git credential helper for GITHUB_TOKEN
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "Configuring GitHub token authentication..."
    git config --global credential.helper '!f() { echo "username=git"; echo "password=$GITHUB_TOKEN"; }; f'
fi

# Start SSH server (requires root)
sudo /usr/sbin/sshd

echo "SSH server started on port 22"

# Initialize firewall if requested
if [ "${INIT_FIREWALL:-false}" = "true" ]; then
    echo "Initializing firewall..."
    sudo /usr/local/bin/init-firewall.sh
    echo "Firewall initialized"
fi

# Ensure workspace is writable by node user
if [ ! -w /workspace ]; then
    echo "Fixing /workspace permissions..."
    sudo chown node:node /workspace
fi

# Clone repository if REPO_URL is provided
if [ -n "${REPO_URL:-}" ]; then
    REPO_DIR="${REPO_DIR:-/workspace/repo}"

    # Check if directory exists and has content (mounted from host)
    if [ -d "$REPO_DIR" ] && [ "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
        echo "Directory $REPO_DIR already exists with content, skipping clone"
    elif [ -d "$REPO_DIR/.git" ]; then
        echo "Git repository found in $REPO_DIR, skipping clone"
    else
        echo "Cloning repository $REPO_URL to $REPO_DIR..."
        git clone "$REPO_URL" "$REPO_DIR" || {
            echo "WARNING: Failed to clone repository. Continuing anyway..."
            mkdir -p "$REPO_DIR"
        }
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
