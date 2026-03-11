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
  new <name> <path> [claude args...]  Create a new container and start Claude Code
  attach <name>                       Re-attach to an existing container (resumes session)
  ls                                  List all cw containers
  rm <name>                           Remove a container
  rm --all                            Remove all stopped cw containers
  rebuild                             Rebuild the Docker image

Environment variables:
  CW_GITHUB_TOKEN_FILE  GitHub token file (default: ~/.claude-worker/github-token)
  CW_MEMORY             Container memory limit (default: 8g)
  CW_CPUS               Container CPU limit (default: 4)

Examples:
  cw new fix-auth ~/src/myproject
  cw new experiment /tmp/scratch
  cw new bugfix ~/src/myproject 'fix the login bug'
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
    local name="${1:?Usage: cw new <name> <path> [claude args...]}"
    local project_path="${2:?Usage: cw new <name> <path> [claude args...]}"
    shift 2
    local claude_args=("$@")

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

    # Check for existing running container for this project
    local existing
    existing="$(find_containers "$project" --running | head -1)"
    if [[ -n "$existing" ]]; then
        echo "A running container already exists for '${project}': ${existing}" >&2
        echo "Use 'cw attach ${project}' to re-attach, or 'cw rm ${project}' first." >&2
        exit 1
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

    # Container name: cw-<project> (deterministic, one per project)
    local container_name="${CONTAINER_PREFIX}-${project}"

    echo "Creating container: ${container_name}"
    echo "Project: ${project_path}"
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
        --memory="${MEMORY_LIMIT}" \
        --cpus="${CPU_LIMIT}" \
        \
        --net=host \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        \
        --user 1000:1000 \
        \
        "$IMAGE" \
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
    [ -n "$TMUX" ] && tmux rename-window "$project"
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
            [ -n "$TMUX" ] && tmux rename-window "$project"
            exec docker attach "$container_name"
            ;;
        exited)
            echo "Restarting stopped container: ${container_name}"
            [ -n "$TMUX" ] && tmux rename-window "$project"
            exec docker start -ai "$container_name"
            ;;
        *)
            echo "Container ${container_name} is in state '${state}', cannot attach." >&2
            exit 1
            ;;
    esac
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

cmd_rebuild() {
    echo "Rebuilding claude-worker image..."
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    # If cw is a symlink, resolve to the real directory
    if [[ -L "$0" ]]; then
        script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    fi
    docker build \
        --build-arg USER_UID="$(id -u)" \
        --build-arg USER_GID="$(id -g)" \
        -t claude-worker:latest \
        "$script_dir"
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
    ls)      cmd_ls ;;
    rm)      cmd_rm "$@" ;;
    rebuild) cmd_rebuild ;;
    help)    usage ;;
    *)
        echo "Unknown command: ${COMMAND}" >&2
        usage
        ;;
esac
