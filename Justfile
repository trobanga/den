# Justfile for Den - Secure Claude Code Container

# List available recipes
default:
    @just --list

# Build the default Docker image
build:
    docker build -t den:latest \
        --build-arg CLAUDE_CODE_VERSION=latest \
        --build-arg TZ=UTC \
        -f Dockerfile .

# Build a specific flavor (e.g., flutter, go)
build-flavor flavor:
    docker build -t den:{{flavor}} \
        --build-arg CLAUDE_CODE_VERSION=latest \
        --build-arg TZ=UTC \
        -f Dockerfile.{{flavor}} .

# Build all available Docker images (default + all flavors)
build-all:
    @echo "Building all Docker images..."
    @just build
    @just build-flavor flutter
    @just build-flavor go
    @just build-flavor rust
    @echo "✓ All images built successfully"

# Force rebuild without cache (default image)
rebuild:
    docker build --no-cache -t den:latest \
        --build-arg CLAUDE_CODE_VERSION=latest \
        --build-arg TZ=UTC \
        -f Dockerfile .

# Force rebuild a specific flavor without cache
rebuild-flavor flavor:
    docker build --no-cache -t den:{{flavor}} \
        --build-arg CLAUDE_CODE_VERSION=latest \
        --build-arg TZ=UTC \
        -f Dockerfile.{{flavor}} .

# Force rebuild all images without cache (default + all flavors)
rebuild-all:
    @echo "Rebuilding all Docker images (no cache)..."
    @just rebuild
    @just rebuild-flavor flutter
    @just rebuild-flavor go
    @just rebuild-flavor rust
    @echo "✓ All images rebuilt successfully"

# List all den Docker images
images:
    @docker images | grep -E "(REPOSITORY|den)" || echo "No den images found"

# Run container using run.sh script (pass additional flags as arguments)
run *FLAGS:
    ./run.sh {{FLAGS}}

# Run container with auto-start Claude Code
run-claude *FLAGS:
    ./run.sh -c {{FLAGS}}

# Run container with a specific flavor
run-flavor flavor *FLAGS:
    ./run.sh -F {{flavor}} -c {{FLAGS}}

# Run container with git worktree mode
run-worktree *FLAGS:
    ./run.sh -W -c {{FLAGS}}

# Stop a container (default: den)
stop container="den":
    @echo "Stopping {{container}}..."
    docker stop {{container}} && docker rm {{container}} || true
    @echo "✓ Container stopped and removed"

# Restart a container (default: den)
restart container="den":
    @echo "Restarting {{container}}..."
    docker restart {{container}}
    @echo "✓ Container restarted"

# View logs for a container (default: den)
logs container="den":
    docker logs -f {{container}}

# SSH into a container (default: den)
ssh container="den":
    #!/usr/bin/env bash
    SSH_PORT=$(docker port {{container}} 22 2>/dev/null | cut -d: -f2)
    if [ -z "$SSH_PORT" ]; then
        echo "ERROR: Container {{container}} is not running or port not found"
        exit 1
    fi
    ssh -p $SSH_PORT node@localhost

# SSH into container and attach to tmux session
ssh-tmux container="den":
    #!/usr/bin/env bash
    SSH_PORT=$(docker port {{container}} 22 2>/dev/null | cut -d: -f2)
    if [ -z "$SSH_PORT" ]; then
        echo "ERROR: Container {{container}} is not running or port not found"
        exit 1
    fi
    ssh -p $SSH_PORT node@localhost -t tmux attach -t claude

# List all running den containers
list:
    @echo "Running den containers:"
    @docker ps --filter "ancestor=den:latest" --filter "ancestor=den:flutter" --filter "ancestor=den:go" --filter "ancestor=den:rust" --format "table {{{{.Names}}\t{{{{.Image}}\t{{{{.Status}}\t{{{{.Ports}}" || echo "No running containers"

# Execute a command in a running container
exec container *COMMAND:
    docker exec -it {{container}} {{COMMAND}}

# Execute a command in the default 'den' container
exec-den *COMMAND:
    docker exec -it den {{COMMAND}}

# Open an interactive shell in a running container (default: den)
shell container="den":
    docker exec -it {{container}} zsh

# Remove den Docker images
clean:
    @echo "Removing den:latest image..."
    docker rmi den:latest || true

# Remove a specific flavor image
clean-flavor flavor:
    @echo "Removing den:{{flavor}} image..."
    docker rmi den:{{flavor}} || true

# Remove all den Docker images
clean-all:
    @echo "Removing all den images..."
    docker images | grep "^den" | awk '{print $1":"$2}' | xargs -r docker rmi || true
    @echo "✓ All den images removed"

# Docker system prune (careful: removes all unused containers, networks, images)
prune:
    @echo "WARNING: This will remove all unused containers, networks, and images"
    @echo "Press Ctrl+C to cancel or Enter to continue..."
    @read
    docker system prune -a

# Stop all running den containers
stop-all:
    @echo "Stopping all den containers..."
    @docker ps --filter "ancestor=den:latest" --filter "ancestor=den:flutter" --filter "ancestor=den:go" --filter "ancestor=den:rust" --format "{{{{.Names}}" | xargs -r -I {} docker stop {} && docker rm {} || true
    @echo "✓ All den containers stopped"

# Full rebuild: stop all containers, remove all images, rebuild all
reset: stop-all clean-all build-all
    @echo "✓ Complete reset finished"

# Show container status and resource usage
status:
    @echo "=== Container Status ==="
    @just list
    @echo ""
    @echo "=== Resource Usage ==="
    @docker stats --no-stream --format "table {{{{.Container}}\t{{{{.CPUPerc}}\t{{{{.MemUsage}}\t{{{{.NetIO}}" $(docker ps --filter "ancestor=den:latest" --filter "ancestor=den:flutter" --filter "ancestor=den:go" --filter "ancestor=den:rust" --format "{{{{.Names}}") 2>/dev/null || echo "No running containers"

# Show help for run.sh script
help:
    ./run.sh --help
