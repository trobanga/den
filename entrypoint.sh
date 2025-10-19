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

# Copy Claude config directory from host if available
if [ -d /tmp/host_claude ]; then
    echo "Copying Claude config directory..."
    # Remove existing .claude if present, then copy from host
    rm -rf /home/node/.claude
    cp -r /tmp/host_claude /home/node/.claude
    # Ensure all files are writable by the node user
    chmod -R u+w /home/node/.claude
    echo "Claude config directory copied and made writable"
fi

# Copy Claude config file from host if available
if [ -f /tmp/host_claude.json ]; then
    cp /tmp/host_claude.json /home/node/.claude.json
    chmod 644 /home/node/.claude.json
    echo "Claude config file copied and made writable"
fi

# Configure git credential helper for GITHUB_TOKEN
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "Configuring GitHub token authentication..."
    # Use GIT_CONFIG_GLOBAL to avoid potential mount conflicts with mounted .gitconfig
    export GIT_CONFIG_GLOBAL=/tmp/.gitconfig
    # Configure git to inject token into GitHub URLs
    git config --global url."https://git:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
    # Make GIT_CONFIG_GLOBAL available in user shells
    echo "export GIT_CONFIG_GLOBAL=/tmp/.gitconfig" >> /home/node/.bashrc
    if [ -f /home/node/.zshrc ]; then
        echo "export GIT_CONFIG_GLOBAL=/tmp/.gitconfig" >> /home/node/.zshrc
    fi
    if [ -f /home/node/.profile ]; then
        echo "export GIT_CONFIG_GLOBAL=/tmp/.gitconfig" >> /home/node/.profile
    else
        echo "export GIT_CONFIG_GLOBAL=/tmp/.gitconfig" > /home/node/.profile
    fi
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

    # Convert SSH URLs to HTTPS for token-based authentication
    CLONE_URL="$REPO_URL"
    if [[ "$CLONE_URL" =~ ^git@github\.com:(.+)$ ]]; then
        CLONE_URL="https://github.com/${BASH_REMATCH[1]}"
        echo "Converted SSH URL to HTTPS: $CLONE_URL"
    fi

    # Check if directory exists and has content (mounted from host)
    if [ -d "$REPO_DIR" ] && [ "$(ls -A "$REPO_DIR" 2>/dev/null)" ]; then
        echo "Directory $REPO_DIR already exists with content, skipping clone"
    elif [ -d "$REPO_DIR/.git" ]; then
        echo "Git repository found in $REPO_DIR, skipping clone"
    else
        echo "Cloning repository $CLONE_URL to $REPO_DIR..."
        git clone "$CLONE_URL" "$REPO_DIR" || {
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

    # Start Claude in a detached tmux session with shell fallback
    # The '|| exec bash' ensures that if claude exits, we get a shell instead of closing the session
    tmux new-session -d -s claude "cd $REPO_DIR && $CLAUDE_CMD || exec bash"
    echo "Claude Code started in tmux session 'claude'"
    echo "Connect with: tmux attach -t claude"
fi

echo "Container ready! Connect via SSH on port 22"
echo "Working directory: $REPO_DIR"

# Keep container running by tailing a log or using wait
tail -f /dev/null
