# sandcastle

Disposable, sandboxed Docker containers for running AI coding agents (Claude Code, OpenAI Codex) against local repos. The `cw` command wraps Docker to give each agent session its own isolated environment while sharing credentials, caches, and session history from the host.

## What problem this solves

Running AI agents with full autonomy (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`) is useful but risky on a bare host. This project provides the sandbox: each agent runs in a locked-down container (all capabilities dropped except NET_RAW, PID limits, memory/CPU caps) so it can't damage the host, while still having full network access and read-write access to the mounted project.

## Architecture

**Core files, no dependencies beyond Docker and bash:**

- `setup.sh` -- One-time host setup: creates a `claude-worker` OS user, configures ulimits, prompts for a GitHub PAT, installs the `cw` and `expose` symlinks, builds the Docker image, checks Claude OAuth credentials, and optionally starts the web portal.
- `Dockerfile` -- Ubuntu 24.04 image with Node.js, Python (via uv), Go, Rust, Claude Code, Codex CLI, gh, and common dev tools pre-installed. Optional build args for LaTeX (`WITH_LATEX=1`) and Tezos/Octez toolchain (`WITH_TEZOS=1`).
- `cw` -- The main CLI. Manages container lifecycle (new, attach, shell, ls, rm, set, rebuild). This is the only file users interact with after setup.
- `AGENT_CONTEXT.md` -- Injected into every agent's system prompt (via `claude --append-system-prompt`) so agents understand they're sandboxed and know how to use the portal.
- `install-nvidia-toolkit.sh` -- Optional helper to install the NVIDIA Container Toolkit for GPU passthrough.
- `portal/` -- Optional web portal (see below). Independent of `cw`; either can be used without the other.

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
4. `exec`s into the selected agent, passing `--append-system-prompt` with the contents of `AGENT_CONTEXT.md` (read on the host at `cw new` time and passed in via the `CW_SYSTEM_PROMPT` env var) when running Claude

The workspace is at `/home/coder/workspace/<name>`. The `cw shell` command opens a root shell via `nsenter` for debugging.

## Web portal

`portal/` is a small Docker Compose stack — Traefik (reverse proxy) + Homepage (dashboard) — that fronts the ad-hoc web servers agents start (Flask, Streamlit, Jupyter, …) so they're reachable through one address (`http://<host>:8080`) instead of a grab-bag of ports.

**Why a file provider, not Docker labels.** The conventional Traefik pattern is label-driven Docker discovery, but it doesn't fit here: the web servers are *processes inside* already-running cw containers (which use host networking), not standalone containers — there's nothing to put labels on. So Traefik uses its **file provider** watching `portal/dynamic/`, and a small `expose` script writes one route file per service.

**Pieces:**
- `portal/docker-compose.yml` -- Traefik + Homepage, both on host networking (so Traefik can reach `127.0.0.1:<port>` services and Homepage is reachable for the catch-all route).
- `portal/traefik.yml` -- Static config: `web` entrypoint on `:8080`, file provider watching `dynamic/` with `watch: true`, API enabled for the Homepage widget.
- `portal/dynamic/homepage.yml` -- The only tracked route: a `PathPrefix(/)` catch-all at `priority: 1` sending unmatched traffic to Homepage. Service routes get higher auto-priority from their longer path prefixes.
- `portal/dynamic/<name>.yml`, `portal/services/<name>` -- Written by `expose`, gitignored. The dynamic config is a router + `stripPrefix` middleware + load-balancer service pointing at `127.0.0.1:<port>`; the services file holds `<port> <description>` for the dashboard.
- `portal/homepage/` -- Homepage config. `settings.yaml` and `widgets.yaml` are tracked; `services.yaml` is regenerated by `expose` from the `services/` dir and is gitignored, as are the files Homepage auto-creates on first run.
- `portal/expose` -- `expose add <name> <port> [description]` / `rm <name>` / `ls`. Resolves its data dir from `$PORTAL_DIR` if set (the case inside containers, where the script and data dirs are mounted to different paths), otherwise from its own location next to the data dirs (the host case). Refuses reserved names (`api`, `dashboard`, `traefik`, `homepage`).

**cw integration.** `cw new` mounts `portal/expose` to `/usr/local/bin/expose` (read-only, on PATH) and the three data dirs (`dynamic/`, `services/`, `homepage/`) under `/home/coder/.portal/`, and sets `PORTAL_DIR=/home/coder/.portal`. So an agent that starts a server can run `expose add ...` itself; `AGENT_CONTEXT.md` tells it to. Since containers use host networking, the port is already on the host — `expose` only registers the route. Nothing else about the portal is mounted in.

**No auth.** Both Traefik and Homepage are unauthenticated. The portal is meant to live behind Tailscale or bound to localhost; don't expose `:8080` publicly.

## Image variants

- `claude-worker:latest` -- Default image with all standard tooling
- `claude-worker:latex` -- Adds TeXLive, XeTeX, Pandoc
- `claude-worker:tezos` -- Adds Octez binaries (node, client, baker, smart-rollup-node), smart-rollup-installer, wasm-debugger
- Tags compose: `claude-worker:latex-tezos` for both
