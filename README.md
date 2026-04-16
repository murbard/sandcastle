# claude-worker

Run AI coding agents in sandboxed Docker containers. Point `cw` at a local repo, and it spins up an isolated environment with Claude Code or OpenAI Codex running fully autonomously -- the container is the sandbox.

## Why

AI coding agents work best when you let them run without approval prompts. But giving an agent unrestricted access to your host is a bad idea. `claude-worker` solves this by running each agent in a locked-down container: capabilities dropped, PID and memory limits enforced, but full network access and read-write access to the project directory. The agent can do whatever it wants inside the box.

This also makes it easy to run multiple agents in parallel on different branches of the same repo, each in its own container with its own conversation history.

## Quick start

```bash
git clone https://github.com/murbard/claude-worker.git
cd claude-worker
./setup.sh
```

Setup will:
- Check prerequisites (Docker, git, Claude CLI)
- Create a `claude-worker` OS user with resource limits
- Prompt for a GitHub personal access token
- Build the Docker image
- Install the `cw` command to `~/.local/bin`

Then:

```bash
# Start Claude on a project
cw new fix-auth ~/src/myproject

# Start with an initial prompt
cw new fix-auth ~/src/myproject 'fix the login bug'

# Use Codex instead
cw new fix-auth ~/src/myproject --codex

# Re-attach after detaching
cw attach fix-auth

# List containers
cw ls

# Clean up
cw rm fix-auth
```

## Features

**Agent support.** Claude Code (default) and OpenAI Codex. Both run fully autonomous. Switch agents on an existing container with `cw attach <name> --codex` or `--claude`.

**Session persistence.** Conversation history survives container restarts and even `cw rm` / `cw new` cycles, as long as you reuse the same container name. Sessions are stored on the host in `~/.claude/`.

**Git worktree support.** If you point `cw` at a git worktree, it automatically mounts the parent directory so git references resolve, while giving each branch its own conversation history.

```bash
# Work on multiple branches in parallel
cw new feature-a ~/src/project/feature-a
cw new feature-b ~/src/project/feature-b
```

**Resource control.** Set memory and CPU limits per container, with a `max` shorthand for unlimited.

```bash
cw new ml-train ~/src/model --memory max --cpus max
cw set ml-train --memory 32g --cpus 8
```

**GPU passthrough.** Containers get GPU access by default (requires NVIDIA Container Toolkit). Control with `--gpus`.

```bash
cw new train ~/src/model --gpus 0,1     # specific GPUs
cw new train ~/src/model --gpus none    # no GPU
```

**Optional toolchains.** Build image variants with additional tools:

```bash
cw rebuild --with-latex              # TeXLive, XeTeX, Pandoc
cw rebuild --with-tezos              # Octez node, client, baker, smart rollup tools
cw new paper ~/src/thesis --with-latex
```

**Debugging.** Open a root shell in a running container:

```bash
cw shell fix-auth
```

## Pre-installed tools

The base image (Ubuntu 24.04) includes:

- **Languages:** Node.js 22, Python 3.12 (via uv), Go 1.24, Rust (stable), C/C++/Clang
- **AI agents:** Claude Code, OpenAI Codex CLI
- **Dev tools:** git, gh, ripgrep, fd, jq, sqlite3, tmux, htop
- **Package managers:** npm, pnpm, uv, cargo

## Security model

Containers are locked down:
- All Linux capabilities dropped (except NET_RAW)
- PID limit: 512
- File descriptor limit: 4096
- Configurable memory and CPU caps (default: 8 GB / 4 CPUs)
- Runs as non-root (uid 1000)
- Host-level `claude-worker` user with ulimits as defense in depth

Network access is unrestricted (`--net=host`) since agents need to reach git remotes, package registries, and APIs.

The project directory is bind-mounted read-write. Credentials (`~/.claude`, `~/.codex`) and caches (`~/.cache/uv`) are also bind-mounted to avoid re-authentication and redundant downloads.

## Requirements

- Linux (tested on Ubuntu 24.04)
- Docker
- Claude CLI (`npm install -g @anthropic-ai/claude-code`) with an active session
- For Codex: OpenAI API key at `~/.claude-worker/openai-api-key`
- For GPU support: NVIDIA drivers + Container Toolkit (run `./install-nvidia-toolkit.sh`)

## Commands

| Command | Description |
|---|---|
| `cw new <name> <path> [options]` | Create a container and start an agent |
| `cw attach <name> [--codex\|--claude]` | Re-attach or switch agent |
| `cw shell <name>` | Root shell in a running container |
| `cw ls` | List all cw containers |
| `cw rm <name>` | Remove a container |
| `cw rm --all` | Remove all stopped containers |
| `cw set <name> --memory <m> --cpus <n>` | Update resource limits |
| `cw rebuild [--with-latex] [--with-tezos]` | Rebuild the Docker image |

## License

MIT
