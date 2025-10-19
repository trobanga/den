FROM node:20

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
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
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

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
  -x

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}


# Copy and set up firewall script
COPY init-firewall.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh && \
  echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/sbin/sshd" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/bin/ssh-keygen" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/sbin/rsyslogd" >> /etc/sudoers.d/node-firewall && \
  echo "node ALL=(root) NOPASSWD: /usr/bin/chown" >> /etc/sudoers.d/node-firewall && \
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
  echo "AllowUsers node" >> /etc/ssh/sshd_config

# Set up SSH for node user and unlock account for SSH access
RUN mkdir -p /home/node/.ssh && \
  chown -R node:node /home/node/.ssh && \
  chmod 700 /home/node/.ssh && \
  usermod -p '*' node

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
