# Current Issue: Git Config File Conflict

## Problem
Containers are crashing on startup with error:
```
error: could not write config file /home/node/.gitconfig: Device or resource busy
```

This happens in `entrypoint.sh` when configuring GitHub token authentication.

## Root Cause
The `git config --global` command tries to write to `/home/node/.gitconfig`, but this conflicts with mounted volumes (specifically the `.claude` directory mounted at `/home/node/.claude`).

## Attempted Fix (NOT YET APPLIED)
Modified `entrypoint.sh` to use `/tmp/.gitconfig` instead:
```bash
export GIT_CONFIG_GLOBAL=/tmp/.gitconfig
git config --global credential.helper '!f() { echo "username=git"; echo "password=$GITHUB_TOKEN"; }; f'
echo "export GIT_CONFIG_GLOBAL=/tmp/.gitconfig" >> /home/node/.bashrc
```

**This fix is committed to git but the Docker image hasn't been rebuilt yet.**

## Next Steps

1. **Stop all running containers:**
   ```bash
   docker stop clauntainer-clauntainer clauntainer-task
   docker rm clauntainer-clauntainer clauntainer-task
   ```

2. **Force remove the old image:**
   ```bash
   docker rmi -f clauntainer:latest
   ```

3. **Rebuild with the fix:**
   ```bash
   cd ~/code/clauntainer
   docker build -t clauntainer:latest .
   ```

4. **Test with GitHub token:**
   ```bash
   export GITHUB_TOKEN=ghp_yourTokenHere
   cd ~/path/to/your/repo
   clauntainer -c
   ```

5. **Verify it works:**
   ```bash
   clauntainer ssh clauntainer-yourrepo
   # Inside container:
   cd /workspace/repo
   git pull  # Should work with token
   ```

## Current System State

- **Git commits:** All fixes are committed to main branch
- **Docker image:** Still using OLD code (before the fix)
- **Running containers:**
  - `clauntainer-clauntainer` - Running but no GITHUB_TOKEN (port 29302)
  - `clauntainer-task` - Crashed due to git config error

## Files Modified
- `entrypoint.sh` - Fixed git config to use `/tmp/.gitconfig`
- `run.sh` - Added SSH subcommand, port display fix, URL conversion

## Recent Commits
```
d7ae6db - Fix git config file conflict with mounted volumes
39e30df - Add SSH subcommand for easy container connection
5ec1b22 - Fix: Display actual assigned port instead of requested port
0f6cedb - Fix: Convert SSH URLs to HTTPS in entrypoint for token auth
a06288c - Simplify authentication: Use GitHub tokens instead of SSH keys
5200499 - Add parallel container support with auto-port assignment
```

## Testing Checklist
After rebuild:
- [ ] Container starts without crashing
- [ ] Git config writes to `/tmp/.gitconfig` successfully
- [ ] `git pull` works with GITHUB_TOKEN
- [ ] `git push` works with GITHUB_TOKEN
- [ ] SSH connection works: `clauntainer ssh <name>`
- [ ] Tmux attachment works: `clauntainer ssh <name> -t`
- [ ] Multiple parallel containers work
- [ ] Port is displayed correctly after start

## Alternative Solution (if above doesn't work)
Instead of using git config, inject token directly into URLs:
```bash
# In entrypoint.sh, instead of git config:
if [ -n "${GITHUB_TOKEN:-}" ]; then
    # Configure git to use token in URLs
    git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi
```
This might be simpler and avoid any file conflicts.
