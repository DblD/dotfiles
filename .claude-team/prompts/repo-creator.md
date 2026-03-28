# Create GitLab Repo and Push Sanitized Files

## Context

Another agent (sanitizer) is creating sanitized files in `/tmp/openfortivpn-wrapper/`. Your job is to create the GitLab repo and push everything once the files are ready.

## Pre-requisite: Wait for sanitizer

Before doing anything, check if the sanitizer is done:

```bash
cat /Users/dbld/.code/dotfiles/.claude-team/agents/sanitizer.md
```

If status is not "Done", wait 30 seconds and check again. Repeat until done or 10 minutes elapsed.

Also verify the files exist:
```bash
ls -la /tmp/openfortivpn-wrapper/
ls -la /tmp/openfortivpn-wrapper/bin/
```

## Steps

### 1. Create the GitLab repo

```bash
cd /tmp/openfortivpn-wrapper
glab repo create mindworks-software/lab/openfortivpn-wrapper \
  --description "OpenFortiVPN split-tunnel wrapper with cross-platform support, auto-reconnect, and DNS leak protection" \
  --defaultBranch main \
  --public
```

If the `glab repo create` command doesn't support the full path, use the API:

```bash
glab api projects -X POST \
  -f "name=openfortivpn-wrapper" \
  -f "namespace_id=46" \
  -f "description=OpenFortiVPN split-tunnel wrapper with cross-platform support, auto-reconnect, and DNS leak protection" \
  -f "visibility=internal" \
  -f "default_branch=main"
```

The namespace_id for `mindworks-software/lab` is `46`.

### 2. Initialize git and push

```bash
cd /tmp/openfortivpn-wrapper
git init -b main
git add .
git commit -m "feat: initial release — OpenFortiVPN split-tunnel wrapper

Cross-platform (macOS + Linux) wrapper for openfortivpn with:
- Strict split-tunnel enforcement (set-routes=0, set-dns=0)
- Default gateway protection and route leak detection
- Split DNS configuration (macOS /etc/resolver, Linux resolvectl)
- DNS leak testing
- Multi-backend session keystore (Keychain, secret-tool, pass, file)
- Auto-reconnect with health monitoring
- Externalized route and DNS configuration
- Input validation and secure credential handling
- Bash completion

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

git remote add origin git@mw-lab-gitlab.netbird.cloud:mindworks-software/lab/openfortivpn-wrapper.git
git push -u origin main
```

### 3. Verify

- Check the repo is accessible: `glab repo view mindworks-software/lab/openfortivpn-wrapper`
- Verify README renders properly
- Print the repo URL for the user

## Constraints

- Do NOT modify any files — just create repo and push what the sanitizer created
- Use `internal` visibility (visible to all GitLab users on the instance)
- Use SSH for git operations (already configured)

## Status File

Update `.claude-team/agents/repo-creator.md`:

```
# Agent: repo-creator
**Status:** In Progress | Blocked | Done
**Current task:** <what>
**Completed:** <what>
**Blockers:** <any>
**Updated:** <timestamp>
```
