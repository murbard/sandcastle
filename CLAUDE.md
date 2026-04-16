# claude-worker

Disposable, sandboxed Docker containers for running AI coding agents (Claude Code, OpenAI Codex) against local repos. The `cw` command wraps Docker to give each agent session its own isolated environment while sharing credentials, caches, and session history from the host.

## What problem this solves

Running AI agents with full autonomy (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`) is useful but risky on a bare host. This project provides the sandbox: each agent runs in a locked-down container (all capabilities dropped except NET_RAW, PID limits, memory/CPU caps) so it can't damage the host, while still having full network access and read-write access to the mounted project.

## Architecture

**Four files, no dependencies beyond Docker and bash:**

- `setup.sh` -- One-time host setup: creates a `claude-worker` OS user, configures ulimits, prompts for a GitHub PAT, installs the `cw` symlink, builds the Docker image, and checks Claude OAuth credentials.
- `Dockerfile` -- Ubuntu 24.04 image with Node.js, Python (via uv), Go, Rust, Claude Code, Codex CLI, gh, and common dev tools pre-installed. Optional build args for LaTeX (`WITH_LATEX=1`) and Tezos/Octez toolchain (`WITH_TEZOS=1`).
- `cw` -- The main CLI. Manages container lifecycle (new, attach, shell, ls, rm, set, rebuild). This is the only file users interact with after setup.
- `install-nvidia-toolkit.sh` -- Optional helper to install the NVIDIA Container Toolkit for GPU passthrough.

## Design decisions

**Bind mounts, not copies.** The project directory is bind-mounted into the container so changes are immediately visible on the host. Credentials (`~/.claude`, `~/.claude.json`, `~/.codex`) and caches (`~/.cache/uv`) are also bind-mounted to avoid re-auth and re-downloads.

**Session persistence.** Claude sessions are stored in `~/.claude/projects/` on the host, keyed by the container's working directory path (e.g., `-home-coder-workspace-foo`). The container startup script checks if `.jsonl` session files exist for the current project path; if so, it passes `--continue` to Claude (or `resume --last` to Codex) so that deleting and recreating a container with the same name preserves conversation history.

**Git worktree support.** When the target path is a git worktree (`.git` is a file, not a directory), `cw` detects this and mounts the common parent directory (containing both the main repo and sibling worktrees) so that git's relative references resolve. The working directory is set to the specific worktree subfolder, giving each branch its own Claude session history. This means sibling worktrees are visible within each container -- unavoidable since git worktrees use relative paths to the shared `.git` directory.

**Container name = identity.** The container name (`cw-<name>`) determines the internal workspace path (`/home/coder/workspace/<name>`), which determines the Claude session key. Reusing a name preserves history; using a different name starts fresh. Don't reuse names across unrelated projects.

**Security layers:**
- All Linux capabilities dropped except NET_RAW (needed for pip/npm to work)
- PID limit (512), file descriptor limit (4096), configurable memory and CPU caps
- Runs as uid 1000 (non-root) inside the container
- `--net=host` for simplicity (agents need network access for git, APIs, package installs)
- Host-level `claude-worker` user with ulimits as defense in depth

**Agent selection.** Claude is the default. Pass `--codex` to use OpenAI Codex instead. Both run fully autonomous by default (permissions bypassed, since the container is the sandbox). The `cw attach` command can switch agents on an existing container.

## Container internals

The container runs as user `coder` (uid 1000). The entrypoint is a bash script that:
1. Configures git credentials (using the GitHub token passed via env var)
2. Checks for an agent override file (`/tmp/.cw-agent`, written by `cw attach --codex/--claude`)
3. Detects existing sessions and resumes or starts fresh accordingly
4. `exec`s into the selected agent

The workspace is at `/home/coder/workspace/<name>`. The `cw shell` command opens a root shell via `nsenter` for debugging.

## Image variants

- `claude-worker:latest` -- Default image with all standard tooling
- `claude-worker:latex` -- Adds TeXLive, XeTeX, Pandoc
- `claude-worker:tezos` -- Adds Octez binaries (node, client, baker, smart-rollup-node), smart-rollup-installer, wasm-debugger
- Tags compose: `claude-worker:latex-tezos` for both
