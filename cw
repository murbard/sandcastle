#!/usr/bin/env bash
set -euo pipefail

# --- Configuration (override via env) ---
PROJECTS_ROOT="${CW_PROJECTS_ROOT:-$HOME/src}"
CLAUDE_DIR="${CW_CLAUDE_DIR:-$HOME/.claude}"
GITHUB_TOKEN_FILE="${CW_GITHUB_TOKEN_FILE:-$HOME/.claude-worker/github-token}"
OPENAI_KEY_FILE="${CW_OPENAI_KEY_FILE:-$HOME/.claude-worker/openai-api-key}"
IMAGE="${CW_IMAGE:-claude-worker:latest}"
MEMORY_LIMIT="${CW_MEMORY:-8g}"
CPU_LIMIT="${CW_CPUS:-4}"
CONTAINER_PREFIX="cw"

# --- Helpers ---

usage() {
    cat <<EOF
Usage: cw <command> [args...]

Commands:
  new <name> <path> [options] [agent args...]
                                      Create a new container and start an AI agent
      --codex                         Use OpenAI Codex instead of Claude (default: claude)
      --with-latex                    Use LaTeX-enabled image
      --with-tezos                    Use Tezos/Octez-enabled image
      --memory <mem|max>              Memory limit (default: \$CW_MEMORY or 8g, "max" = unlimited)
      --cpus <n|max>                  CPU limit (default: \$CW_CPUS or 4, "max" = unlimited)
      --gpus <all|none|0,1,...>       GPU access (default: all)
  attach <name> [--codex|--claude]    Re-attach or switch agent in an existing container
  shell <name>                        Open a root shell in a running container
  ls                                  List all cw containers
  rm <name>                           Remove a container
  rm --all                            Remove all stopped cw containers
  set <name> --memory <mem|max> [--cpus <n|max>]
                                      Update resource limits on a container (running or stopped)
  rebuild [--with-latex] [--with-tezos]
                                      Rebuild the Docker image

Environment variables:
  CW_GITHUB_TOKEN_FILE    GitHub token file (default: ~/.claude-worker/github-token)
  CW_OPENAI_KEY_FILE      OpenAI API key file (default: ~/.claude-worker/openai-api-key)
  CW_MEMORY               Container memory limit (default: 8g)
  CW_CPUS                 Container CPU limit (default: 4)

Examples:
  cw new fix-auth ~/src/myproject
  cw new fix-auth ~/src/myproject --codex
  cw new experiment /tmp/scratch 'fix the login bug'
  cw new paper ~/src/thesis --with-latex
  cw new tez ~/src/tezos --with-tezos
  cw new ml-train ~/src/model --memory max --cpus max --gpus 0,1
  cw attach fix-auth
  cw attach fix-auth --codex
  cw attach fix-auth --claude
  cw set ml-train --memory max --cpus max
  cw rebuild --with-latex
  cw rebuild --with-tezos
  cw ls
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
    local agent="claude"
    local use_latex=0
    local use_tezos=0
    local memory="$MEMORY_LIMIT"
    local cpus="$CPU_LIMIT"
    local gpus="all"
    local agent_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --codex)      agent="codex" ;;
            --claude)     agent="claude" ;;
            --with-latex) use_latex=1 ;;
            --with-tezos) use_tezos=1 ;;
            --memory) memory="$2"; shift ;;
            --cpus)   cpus="$2"; shift ;;
            --gpus)   gpus="$2"; shift ;;
            *) agent_args+=("$1") ;;
        esac
        shift
    done

    # Resolve "max" to unlimited (Docker uses 0 for no limit)
    [[ "$memory" == "max" ]] && memory=0
    [[ "$cpus" == "max" ]]   && cpus=0

    # Default agent args
    if [[ ${#agent_args[@]} -eq 0 ]]; then
        case "$agent" in
            claude) agent_args=(--dangerously-skip-permissions) ;;
            codex)  agent_args=(--dangerously-bypass-approvals-and-sandbox) ;;
        esac
    fi

    # Resolve to absolute path
    project_path="$(cd "$project_path" 2>/dev/null && pwd)" || {
        echo "Error: Directory not found: $project_path" >&2
        exit 1
    }
    local project="$name"

    # Detect git worktree: mount the common parent so git refs resolve,
    # but set workdir to the specific branch for separate Claude histories
    local mount_path="$project_path"
    local container_workdir="/home/coder/workspace/${project}"
    if [[ -f "${project_path}/.git" ]]; then
        local git_common_dir
        git_common_dir="$(cd "$project_path" && realpath "$(git rev-parse --git-common-dir)")"
        local main_repo_dir
        main_repo_dir="$(dirname "$git_common_dir")"
        local worktree_parent
        worktree_parent="$(dirname "$project_path")"
        local mainrepo_parent
        mainrepo_parent="$(dirname "$main_repo_dir")"
        if [[ "$worktree_parent" == "$mainrepo_parent" ]]; then
            mount_path="$worktree_parent"
            local branch_dir
            branch_dir="$(basename "$project_path")"
            container_workdir="/home/coder/workspace/${project}/${branch_dir}"
            echo "Detected git worktree — mounting parent: ${mount_path}"
            echo "Working directory: ${container_workdir}"
        fi
    fi

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

    # OpenAI API key (for codex)
    local openai_key=""
    if [[ -f "$OPENAI_KEY_FILE" ]]; then
        openai_key="$(cat "$OPENAI_KEY_FILE")"
    elif [[ "$agent" == "codex" ]]; then
        echo "Warning: No OpenAI API key at $OPENAI_KEY_FILE (codex won't work)" >&2
    fi

    # Git identity
    local git_name git_email
    git_name="$(git config user.name 2>/dev/null || echo "Claude Worker")"
    git_email="$(git config user.email 2>/dev/null || echo "claude-worker@localhost")"

    # Select image variant
    local image="$IMAGE"
    local image_tag=""
    [[ "$use_latex" -eq 1 ]] && image_tag="${image_tag:+${image_tag}-}latex"
    [[ "$use_tezos" -eq 1 ]] && image_tag="${image_tag:+${image_tag}-}tezos"
    if [[ -n "$image_tag" ]]; then
        image="${IMAGE%:*}:${image_tag}"
        if ! docker image inspect "$image" &>/dev/null; then
            local rebuild_flags=""
            [[ "$use_latex" -eq 1 ]] && rebuild_flags+=" --with-latex"
            [[ "$use_tezos" -eq 1 ]] && rebuild_flags+=" --with-tezos"
            echo "Image ${image} not found. Build it first with: cw rebuild${rebuild_flags}" >&2
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
    echo "Agent: ${agent}"
    echo "Project: ${project_path}"
    echo "Image: ${image}"
    echo "GPUs: ${gpus}"
    echo "Args: ${agent_args[*]}"
    echo ""

    # Create the container (stopped)
    docker create -it \
        --name "$container_name" \
        --hostname "$container_name" \
        \
        -v "${mount_path}:/home/coder/workspace/${project}:rw" \
        -w "${container_workdir}" \
        \
        -v "${CLAUDE_DIR}:/home/coder/.claude:rw" \
        -v "${HOME}/.claude.json:/home/coder/.claude.json:rw" \
        -v "${HOME}/.codex:/home/coder/.codex:rw" \
        -v "/home/claude-worker/.cache/uv:/home/coder/.cache/uv:rw" \
        \
        -e "GITHUB_TOKEN=${github_token}" \
        -e "GH_TOKEN=${github_token}" \
        -e "OPENAI_API_KEY=${openai_key}" \
        -e "GIT_AUTHOR_NAME=${git_name}" \
        -e "GIT_AUTHOR_EMAIL=${git_email}" \
        -e "GIT_COMMITTER_NAME=${git_name}" \
        -e "GIT_COMMITTER_EMAIL=${git_email}" \
        -e "CW_AGENT=${agent}" \
        -e "CW_AGENT_ARGS=${agent_args[*]}" \
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

            # Pick agent: file override > env var > default
            agent="${CW_AGENT:-claude}"
            if [ -f /tmp/.cw-agent ]; then
                agent="$(cat /tmp/.cw-agent)"
            fi

            # Check if a previous session exists for this project
            project_id="$(pwd | tr / -)"
            project_dir="$HOME/.claude/projects/${project_id}"
            has_session=false
            if [ -d "$project_dir" ] && ls "$project_dir"/*.jsonl >/dev/null 2>&1; then
                has_session=true
            fi

            case "$agent" in
                codex)
                    if $has_session; then
                        exec codex resume --last
                    else
                        exec codex ${CW_AGENT_ARGS}
                    fi
                    ;;
                *)
                    if $has_session; then
                        exec claude --continue ${CW_AGENT_ARGS}
                    else
                        exec claude ${CW_AGENT_ARGS}
                    fi
                    ;;
            esac
        ' > /dev/null

    # Set tmux pane title and start
    [ -n "${TMUX:-}" ] && tmux rename-window "$project"
    exec docker start -ai "$container_name"
}

cmd_attach() {
    local project="${1:?Usage: cw attach <project> [--codex|--claude]}"
    shift
    local agent=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --codex)  agent="codex" ;;
            --claude) agent="claude" ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
        shift
    done

    local container_name="${CONTAINER_PREFIX}-${project}"

    # Check if it exists
    if ! docker inspect "$container_name" &>/dev/null; then
        echo "Error: No container found for '${project}'" >&2
        echo "Use 'cw new ${project}' to create one, or 'cw ls' to see what exists." >&2
        exit 1
    fi

    local state
    state="$(docker inspect -f '{{.State.Status}}' "$container_name")"

    case "$state" in
        running)
            if [[ -n "$agent" ]]; then
                # Launch a new agent session inside the running container
                echo "Starting ${agent} in running container: ${container_name}"
                [ -n "${TMUX:-}" ] && tmux rename-window "$project"
                echo "$agent" | docker exec -i "$container_name" tee /tmp/.cw-agent > /dev/null
                case "$agent" in
                    codex)  exec docker exec -it "$container_name" codex resume --last ;;
                    claude) exec docker exec -it "$container_name" claude --continue --dangerously-skip-permissions ;;
                esac
            else
                echo "Attaching to running container: ${container_name}"
                [ -n "${TMUX:-}" ] && tmux rename-window "$project"
                exec docker attach "$container_name"
            fi
            ;;
        created|exited)
            # Write agent override file into the stopped container
            if [[ -n "$agent" ]]; then
                local tmpfile
                tmpfile="$(mktemp)"
                echo "$agent" > "$tmpfile"
                docker cp "$tmpfile" "$container_name":/tmp/.cw-agent
                rm "$tmpfile"
                echo "Starting container with ${agent}: ${container_name}"
            else
                echo "Starting container: ${container_name}"
            fi
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
    local with_tezos=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-latex) with_latex=1 ;;
            --with-tezos) with_tezos=1 ;;
        esac
        shift
    done

    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [[ -L "$0" ]]; then
        script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    fi

    local build_args=(
        --build-arg "USER_UID=$(id -u)"
        --build-arg "USER_GID=$(id -g)"
    )
    local image_tag=""
    local desc="latest"

    if [[ "$with_latex" -eq 1 ]]; then
        build_args+=(--build-arg WITH_LATEX=1)
        image_tag="${image_tag:+${image_tag}-}latex"
        desc+=" + LaTeX"
    fi
    if [[ "$with_tezos" -eq 1 ]]; then
        build_args+=(--build-arg WITH_TEZOS=1)
        image_tag="${image_tag:+${image_tag}-}tezos"
        desc+=" + Tezos"
    fi

    local tag="${image_tag:-latest}"
    echo "Rebuilding claude-worker:${tag} image (${desc})..."
    docker build \
        "${build_args[@]}" \
        -t "claude-worker:${tag}" \
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
