# Agent context

You are running inside a sandcastle container -- a sandboxed Docker environment on the user's machine. This file explains what that means for you.

## Your environment

- You are in a Docker container running Ubuntu 24.04 as user `coder` (uid 1000).
- Your workspace at the current directory is a bind mount of a real directory on the host filesystem. Every file you create, edit, or delete here is immediately visible to the user and vice versa.
- You have sudo access (passwordless) inside the container.
- You have unrestricted network access (the container uses host networking).

## What you can do

- **Edit code freely.** Your workspace is read-write. Commits and pushes go to the real remote.
- **Install packages.** You have npm, pnpm, uv (Python), cargo, go, and apt (via sudo). A shared uv cache is mounted so Python packages don't re-download across containers.
- **Use git.** Git credentials are pre-configured. You can clone, fetch, push, and create PRs using `gh`.
- **Run dev servers, tests, builds.** You have full access to the project and all standard dev tools.
- **Use the network.** Download dependencies, hit APIs, fetch documentation -- no restrictions.

## What you cannot do

- **Access files outside your workspace** (unless they're part of a git worktree mount). You cannot see the user's home directory, other projects, or other containers.
- **Affect the host system.** You have no capabilities (all dropped), a PID limit of 512, and memory/CPU caps. You cannot install host-level services or modify the host OS.
- **Run Docker.** There is no Docker socket inside the container (no Docker-in-Docker).
- **Access GPUs** unless the container was started with GPU passthrough.

## What you'll need to ask the user for

- **Access to other repos or directories.** If the task requires files outside this workspace, ask the user to either mount them or copy them in.
- **Secrets or API keys** beyond what's already in the environment (GITHUB_TOKEN, OPENAI_API_KEY). Check env vars first before asking.
- **Actions on the host.** Anything that needs to happen outside this container -- restarting a service, opening a browser, running a host command.
- **Docker operations.** If the project needs Docker (e.g., docker-compose), you'll need to ask the user to run those commands on the host.

## Git setup

- Git user name and email are set from the host's git config.
- A GitHub token is available as `$GITHUB_TOKEN` and `$GH_TOKEN`. Git credential helper is configured to use it automatically.
- You can push branches and create PRs. The user likely has branch protection on main requiring PR reviews, so push to a feature branch rather than main.

## Session continuity

Your conversation history is persisted on the host. If the container is restarted or recreated with the same name, your session will resume automatically. You don't need to re-establish context.
