FROM debian:bookworm-slim

ARG TZ
ENV TZ="$TZ"

ARG HOST_UID=1000
# CLAUDE_CODE_VERSION kept for compatibility with run.sh; apt repo always installs latest.
ARG CLAUDE_CODE_VERSION=latest

# Use C.UTF-8 (built into glibc, no locale-gen needed)
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
# Give SSH sessions a default UTF-8 locale. sshd does not inherit Docker ENV;
# its pam_env reads /etc/environment. Programs that probe `locale charmap`
# (e.g. Claude Code's unicode detection) otherwise see ASCII and draw box/symbol
# glyphs (─ │ ⎿ ⏺) as `_`. en_US.UTF-8 is generated below so a host that forwards
# it over SSH also resolves to a real UTF-8 charmap instead of ANSI_X3.4-1968.
RUN printf 'LANG=C.UTF-8\nLC_ALL=C.UTF-8\n' >> /etc/environment
ENV DEBIAN_FRONTEND=noninteractive

# Install dev tools, network filtering tools, and Claude Code (apt repo, signed).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    gnupg2 \
    less \
    git \
    procps \
    sudo \
    fzf \
    zsh \
    man-db \
    unzip \
    gh \
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    jq \
    nano \
    vim \
    openssh-server \
    tmux \
    rsyslog \
    ncurses-term \
    locales \
    bubblewrap \
    socat \
  && install -d -m 0755 /etc/apt/keyrings \
  && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
       -o /etc/apt/keyrings/claude-code.asc \
  && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/latest latest main" \
       > /etc/apt/sources.list.d/claude-code.list \
  && apt-get update && apt-get install -y --no-install-recommends claude-code \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Generate en_US.UTF-8 so a host forwarding that locale over SSH resolves to a
# real UTF-8 charmap (Debian-slim ships only C.UTF-8 otherwise).
RUN sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen

# Install bun and pi.dev coding agent (alternative to Claude Code).
RUN ARCH=$(dpkg --print-architecture) && \
  case "$ARCH" in \
    amd64) BUN_ARCH=x64 ;; \
    arm64) BUN_ARCH=aarch64 ;; \
    *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
  esac && \
  curl -fsSL "https://github.com/oven-sh/bun/releases/latest/download/bun-linux-${BUN_ARCH}.zip" -o /tmp/bun.zip && \
  unzip -q /tmp/bun.zip -d /tmp/bun && \
  mv "/tmp/bun/bun-linux-${BUN_ARCH}/bun" /usr/local/bin/bun && \
  chmod +x /usr/local/bin/bun && \
  rm -rf /tmp/bun /tmp/bun.zip && \
  BUN_INSTALL=/usr/local bun add -g @earendil-works/pi-coding-agent

# Install Go 1.25.1
ARG GO_VERSION=1.25.1
RUN ARCH=$(dpkg --print-architecture) && \
  GO_ARCH=$([ "$ARCH" = "amd64" ] && echo "amd64" || echo "arm64") && \
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" && \
  tar -C /usr/local -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" && \
  rm "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

ENV PATH=$PATH:/usr/local/go/bin

# Create node user with HOST_UID so volume mounts share ownership with the host.
RUN useradd -m -u ${HOST_UID} -s /bin/zsh node

# Persist bash history.
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R node:node /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
# .claude/plugins is pre-created node-owned so the persistent named volume
# mounted there by run.sh initializes with node ownership (not root).
RUN mkdir -p /workspace /home/node/.claude/plugins && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -a 'export PATH="$PATH:/usr/local/go/bin"' \
  -x

# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/sbin/sshd" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/bin/ssh-keygen" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/sbin/rsyslogd" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/bin/chown" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /bin/sh -c *" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /bin/chmod /etc/profile.d/git-config.sh" >> /etc/sudoers.d/node-firewall && \
  chmod 0440 /etc/sudoers.d/node-firewall

# Configure SSH server
RUN mkdir -p /run/sshd && \
  ssh-keygen -A && \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
  sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
  sed -i 's/#StrictModes yes/StrictModes no/' /etc/ssh/sshd_config && \
  sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config && \
  sed -i 's/#LogLevel INFO/LogLevel VERBOSE/' /etc/ssh/sshd_config && \
  sed -i 's|#AuthorizedKeysFile.*|AuthorizedKeysFile /home/%u/.ssh/authorized_keys|' /etc/ssh/sshd_config && \
  sed -i 's/^AcceptEnv/#AcceptEnv/' /etc/ssh/sshd_config && \
  echo "AllowUsers node" >> /etc/ssh/sshd_config

# Set up SSH for node user and unlock account for SSH access
RUN mkdir -p /home/node/.ssh && \
  chown -R node:node /home/node/.ssh && \
  chmod 700 /home/node/.ssh && \
  usermod -p '*' node && \
  ssh-keyscan -H github.com >> /home/node/.ssh/known_hosts 2>/dev/null && \
  chown node:node /home/node/.ssh/known_hosts && \
  chmod 644 /home/node/.ssh/known_hosts

# Copy tmux configuration
COPY .tmux.conf /home/node/.tmux.conf
RUN chown node:node /home/node/.tmux.conf

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
