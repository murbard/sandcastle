#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (override via env) ---
PROJECTS_ROOT="${CW_PROJECTS_ROOT:-$HOME/src}"
CLAUDE_DIR="${CW_CLAUDE_DIR:-$HOME/.claude}"
GITHUB_TOKEN_FILE="${CW_GITHUB_TOKEN_FILE:-$HOME/.claude-worker/github-token}"
IMAGE="${CW_IMAGE:-claude-worker:latest}"
MEMORY_LIMIT="${CW_MEMORY:-8g}"
CPU_LIMIT="${CW_CPUS:-4}"
CONTAINER_PREFIX="cw"

# --- Helpers ---

usage() {
    cat <<EOF
Usage: cw <command> [args...]

Commands:
  new <name> <path> [options] [claude args...]
                                      Create a new container and start Claude Code
      --with-latex                    Use LaTeX-enabled image
      --memory <mem|max>              Memory limit (default: \$CW_MEMORY or 8g, "max" = unlimited)
      --cpus <n|max>                  CPU limit (default: \$CW_CPUS or 4, "max" = unlimited)
      --gpus <all|none|0,1,...>       GPU access (default: all)
  attach <name>                       Re-attach to an existing container (resumes session)
  shell <name>                        Open a root shell in a running container
  ls                                  List all cw containers
  rm <name>                           Remove a container
  rm --all                            Remove all stopped cw containers
  set <name> --memory <mem|max> [--cpus <n|max>]
                                      Update resource limits on a container (running or stopped)
  rebuild [--with-latex]              Rebuild the Docker image

Environment variables:
  CW_GITHUB_TOKEN_FILE  GitHub token file (default: ~/.claude-worker/github-token)
  CW_MEMORY             Container memory limit (default: 8g)
  CW_CPUS               Container CPU limit (default: 4)

Examples:
  cw new fix-auth ~/src/myproject
  cw new experiment /tmp/scratch
  cw new bugfix ~/src/myproject 'fix the login bug'
  cw new paper ~/src/thesis --with-latex
  cw new ml-train ~/src/model --memory max --cpus max --gpus 0,1
  cw new safe-task ~/src/app --gpus none
  cw set ml-train --memory max --cpus max
  cw rebuild --with-latex
  cw ls
  cw attach fix-auth
  cw rm fix-auth
  cw rm --all
EOF
    exit 1
}

# Find container(s) matching a project name.
# With --running, only running ones. With --stopped, only stopped.
find_containers() {
    local project="$1"
    shift
    local filters=("--filter" "name=^${CONTAINER_PREFIX}-${project}")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --running) filters+=("--filter" "status=running") ;;
            --stopped) filters+=("--filter" "status=exited") ;;
        esac
        shift
    done
    docker ps -a "${filters[@]}" --format '{{.Names}}' 2>/dev/null
}

# --- Commands ---

cmd_new() {
    local name="${1:?Usage: cw new <name> <path> [--with-latex] [claude args...]}"
    local project_path="${2:?Usage: cw new <name> <path> [--with-latex] [claude args...]}"
    shift 2

    # Parse flags
    local use_latex=0
    local memory="$MEMORY_LIMIT"
    local cpus="$CPU_LIMIT"
    local gpus="all"
    local claude_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-latex) use_latex=1 ;;
            --memory) memory="$2"; shift ;;
            --cpus)   cpus="$2"; shift ;;
            --gpus)   gpus="$2"; shift ;;
            *) claude_args+=("$1") ;;
        esac
        shift
    done

    # Resolve "max" to unlimited (Docker uses 0 for no limit)
    [[ "$memory" == "max" ]] && memory=0
    [[ "$cpus" == "max" ]]   && cpus=0

    # Default to --dangerously-skip-permissions
    if [[ ${#claude_args[@]} -eq 0 ]]; then
        claude_args=(--dangerously-skip-permissions)
    fi

    # Resolve to absolute path
    project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
        echo "Error: Directory not found: $project_path" >&2
        exit 1
    }
    local project="$name"

    # Check for existing container for this project
    local container_name="${CONTAINER_PREFIX}-${project}"
    if docker inspect "$container_name" &>/dev/null; then
        local existing_state
        existing_state="$(docker inspect -f '{{.State.Status}}' "$container_name")"
        case "$existing_state" in
            running)
                echo "A running container already exists for '${project}': ${container_name}" >&2
                echo "Use 'cw attach ${project}' to re-attach, or 'cw rm ${project}' first." >&2
                exit 1
                ;;
            *)
                echo "Removing existing ${existing_state} container: ${container_name}"
                docker rm -f "$container_name" > /dev/null
                ;;
        esac
    fi

    # GitHub token
    local github_token=""
    if [[ -f "$GITHUB_TOKEN_FILE" ]]; then
        github_token="$(cat "$GITHUB_TOKEN_FILE")"
    else
        echo "Warning: No GitHub token at $GITHUB_TOKEN_FILE (git push won't work)" >&2
    fi

    # Git identity
    local git_name git_email
    git_name="$(git config user.name 2>/dev/null || echo "Claude Worker")"
    git_email="$(git config user.email 2>/dev/null || echo "claude-worker@localhost")"

    # Select image variant
    local image="$IMAGE"
    if [[ "$use_latex" -eq 1 ]]; then
        image="${IMAGE%:*}:latex"
        if ! docker image inspect "$image" &>/dev/null; then
            echo "LaTeX image not found. Build it first with: cw rebuild --with-latex" >&2
            exit 1
        fi
    fi

    # Build GPU flag
    local gpu_flag=""
    case "$gpus" in
        none|"") ;;
        all)     gpu_flag="--gpus all" ;;
        *)       gpu_flag="--gpus device=${gpus}" ;;
    esac

    echo "Creating container: ${container_name}"
    echo "Project: ${project_path}"
    echo "Image: ${image}"
    echo "GPUs: ${gpus}"
    echo "Claude args: ${claude_args[*]}"
    echo ""

    # Create the container (stopped)
    docker create -it \
        --name "$container_name" \
        --hostname "$container_name" \
        \
        -v "${project_path}:/home/coder/workspace/${project}:rw" \
        -w "/home/coder/workspace/${project}" \
        \
        -v "${CLAUDE_DIR}:/home/coder/.claude:rw" \
        -v "${HOME}/.claude.json:/home/coder/.claude.json:rw" \
        \
        -e "GITHUB_TOKEN=${github_token}" \
        -e "GH_TOKEN=${github_token}" \
        -e "GIT_AUTHOR_NAME=${git_name}" \
        -e "GIT_AUTHOR_EMAIL=${git_email}" \
        -e "GIT_COMMITTER_NAME=${git_name}" \
        -e "GIT_COMMITTER_EMAIL=${git_email}" \
        -e "CW_CLAUDE_ARGS=${claude_args[*]}" \
        \
        --pids-limit=512 \
        --ulimit nofile=4096:4096 \
        --memory="${memory}" \
        --cpus="${cpus}" \
        \
        --net=host \
        ${gpu_flag:+$gpu_flag} \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        \
        --user 1000:1000 \
        \
        "$image" \
        -c '
            # Git config
            git config --global credential.helper "!f() { echo username=oauth; echo \"password=\${GITHUB_TOKEN}\"; }; f"
            git config --global user.name "${GIT_AUTHOR_NAME}"
            git config --global user.email "${GIT_AUTHOR_EMAIL}"
            git config --global init.defaultBranch main

            # Start Claude Code (resume last session if restarting)
            if [ -f /tmp/.cw-has-run ]; then
                exec claude --continue ${CW_CLAUDE_ARGS}
            else
                touch /tmp/.cw-has-run
                exec claude ${CW_CLAUDE_ARGS}
            fi
        ' > /dev/null

    # Set tmux pane title and start
    [ -n "${TMUX:-}" ] && tmux rename-window "$project"
    exec docker start -ai "$container_name"
}

cmd_attach() {
    local project="${1:?Usage: cw attach <project>}"

    local container_name="${CONTAINER_PREFIX}-${project}"

    # Check if it exists
    if ! docker inspect "$container_name" &>/dev/null; then
        echo "Error: No container found for '${project}'" >&2
        echo "Use 'cw new ${project}' to create one, or 'cw ls' to see what exists." >&2
        exit 1
    fi

    # Check if it's running
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$container_name")"

    case "$state" in
        running)
            echo "Attaching to running container: ${container_name}"
            [ -n "${TMUX:-}" ] && tmux rename-window "$project"
            exec docker attach "$container_name"
            ;;
        created|exited)
            echo "Starting container: ${container_name}"
            [ -n "${TMUX:-}" ] && tmux rename-window "$project"
            exec docker start -ai "$container_name"
            ;;
        *)
            echo "Container ${container_name} is in state '${state}', cannot attach." >&2
            exit 1
            ;;
    esac
}

cmd_shell() {
    local project="${1:?Usage: cw shell <name>}"
    local container_name="${CONTAINER_PREFIX}-${project}"

    if ! docker inspect "$container_name" &>/dev/null; then
        echo "Error: No container '${container_name}' found." >&2
        exit 1
    fi

    local state
    state="$(docker inspect -f '{{.State.Status}}' "$container_name")"
    if [[ "$state" != "running" ]]; then
        echo "Error: Container '${container_name}' is not running (state: ${state})." >&2
        echo "Start it first with 'cw attach ${project}'." >&2
        exit 1
    fi

    local pid
    pid="$(docker inspect -f '{{.State.Pid}}' "$container_name")"
    exec sudo nsenter -t "$pid" -m -u -i -n -p -- bash
}

cmd_ls() {
    echo "CW Containers:"
    echo ""
    docker ps -a \
        --filter "name=^${CONTAINER_PREFIX}-" \
        --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}" \
        2>/dev/null
    local count
    count="$(docker ps -a --filter "name=^${CONTAINER_PREFIX}-" -q 2>/dev/null | wc -l)"
    echo ""
    echo "Total: ${count}"
}

cmd_rm() {
    if [[ "${1:-}" == "--all" ]]; then
        echo "Removing all stopped cw containers..."
        local stopped
        stopped="$(docker ps -a --filter "name=^${CONTAINER_PREFIX}-" --filter "status=exited" -q)"
        if [[ -n "$stopped" ]]; then
            echo "$stopped" | xargs docker rm
            echo "Done."
        else
            echo "No stopped containers to remove."
        fi
        return
    fi

    local project="${1:?Usage: cw rm <project> or cw rm --all}"
    local container_name="${CONTAINER_PREFIX}-${project}"

    if ! docker inspect "$container_name" &>/dev/null; then
        echo "Error: No container '${container_name}' found." >&2
        exit 1
    fi

    local state
    state="$(docker inspect -f '{{.State.Status}}' "$container_name")"

    if [[ "$state" == "running" ]]; then
        echo "Stopping running container ${container_name}..."
        docker stop "$container_name"
    fi

    docker rm "$container_name"
    echo "Removed ${container_name}"
}

cmd_set() {
    local project="${1:?Usage: cw set <name> --memory <mem> [--cpus <n>]}"
    shift
    local container_name="${CONTAINER_PREFIX}-${project}"

    if ! docker inspect "$container_name" &>/dev/null; then
        echo "Error: No container '${container_name}' found." >&2
        exit 1
    fi

    local update_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --memory)
                local mem="$2"; shift
                [[ "$mem" == "max" ]] && mem="-1"
                update_args+=("--memory" "$mem")
                ;;
            --cpus)
                local cpu="$2"; shift
                [[ "$cpu" == "max" ]] && cpu="0"
                update_args+=("--cpus" "$cpu")
                ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done

    if [[ ${#update_args[@]} -eq 0 ]]; then
        echo "Nothing to update. Use --memory and/or --cpus." >&2
        exit 1
    fi

    docker update "${update_args[@]}" "$container_name"
    echo "Updated ${container_name}."
}

cmd_rebuild() {
    local with_latex=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-latex) with_latex=1 ;;
        esac
        shift
    done

    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [[ -L "$0" ]]; then
        script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    fi

    if [[ "$with_latex" -eq 1 ]]; then
        echo "Rebuilding claude-worker:latex image (with LaTeX + Pandoc)..."
        docker build \
            --build-arg USER_UID="$(id -u)" \
            --build-arg USER_GID="$(id -g)" \
            --build-arg WITH_LATEX=1 \
            -t claude-worker:latex \
            "$script_dir"
    else
        echo "Rebuilding claude-worker:latest image..."
        docker build \
            --build-arg USER_UID="$(id -u)" \
            --build-arg USER_GID="$(id -g)" \
            -t claude-worker:latest \
            "$script_dir"
    fi
    echo "Done."
}

# --- Main ---

if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    new)     cmd_new "$@" ;;
    attach)  cmd_attach "$@" ;;
    shell)   cmd_shell "$@" ;;
    ls)      cmd_ls ;;
    rm)      cmd_rm "$@" ;;
    set)     cmd_set "$@" ;;
    rebuild) cmd_rebuild "$@" ;;
    help)    usage ;;
    *)
        echo "Unknown command: ${COMMAND}" >&2
        usage
        ;;
esac
