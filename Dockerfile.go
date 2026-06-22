# Go flavor: the shared base (den:base) plus only the Go toolchain.
# Everything common — apt, bun+pi, node20+bd, user, ssh, tmux, entrypoint — lives
# in the base image (Dockerfile). run.sh / Justfile build den:base first.
FROM den:base

ARG GO_VERSION=1.25.1

# Toolchain installs land in /usr/local, so do them as root.
USER root
RUN ARCH=$(dpkg --print-architecture) && \
  GO_ARCH=$([ "$ARCH" = "amd64" ] && echo "amd64" || echo "arm64") && \
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" && \
  tar -C /usr/local -xzf "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" && \
  rm "go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"

# Container default PATH (docker exec / entrypoint).
ENV PATH=$PATH:/usr/local/go/bin

# Interactive SSH zsh login: base ran zsh-in-docker, append the Go PATH to ~/.zshrc.
RUN echo 'export PATH="$PATH:/usr/local/go/bin"' >> /home/node/.zshrc

USER node
# ENTRYPOINT / EXPOSE / WORKDIR inherited from den:base.
