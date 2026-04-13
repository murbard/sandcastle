FROM ubuntu:24.04

ARG USER_UID=1000
ARG USER_GID=1000
ARG WITH_LATEX=0

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages (Tier 1 + 2) ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core CLI
    sudo \
    git curl wget jq ripgrep fd-find htop tmux unzip xxd sqlite3 \
    tar gzip xz-utils openssh-client ca-certificates \
    # C/C++ toolchain
    gcc g++ clang make cmake pkg-config gdb \
    build-essential \
    # Dev libraries (needed by Python/OCaml packages)
    libsodium-dev libgmp-dev libffi-dev libev-dev libhidapi-dev \
    libssl-dev zlib1g-dev \
    # Media
    ffmpeg \
    # DB clients
    postgresql-client \
    # opam dependencies
    bubblewrap m4 \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js LTS ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm typescript esbuild \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ─────────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# ── Non-root user (ubuntu:24.04 ships with ubuntu:1000, rename it) ─────────────
RUN usermod -l coder -d /home/coder -m ubuntu \
    && groupmod -n coder ubuntu \
    && echo 'coder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/coder

USER coder

# ── Claude Code (native installer) ────────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/coder/.local/bin:${PATH}"

# ── OpenAI Codex CLI ──────────────────────────────────────────────────────────
RUN sudo npm install -g @openai/codex

# ── uv + Python runtime ──────────────────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv python install 3.12 \
    && uv venv /home/coder/.venv --python 3.12
ENV PATH="/home/coder/.venv/bin:/home/coder/.local/bin:${PATH}"
ENV VIRTUAL_ENV="/home/coder/.venv"

# ── Python: heavy ML packages (changes rarely, ~4GB) ─────────────────────────
RUN uv pip install torch torchvision torchaudio

# ── Python: scientific stack ──────────────────────────────────────────────────
RUN uv pip install numpy scipy scikit-learn pandas matplotlib tqdm polars

# ── Python: LLM / AI ─────────────────────────────────────────────────────────
RUN uv pip install openai anthropic tiktoken transformers datasets

# ── Python: web / HTTP / scraping ─────────────────────────────────────────────
RUN uv pip install \
    requests httpx beautifulsoup4 lxml aiohttp \
    flask gunicorn fastapi uvicorn pydantic \
    playwright

# ── Python: crypto ────────────────────────────────────────────────────────────
RUN uv pip install pysodium fastecdsa secp256k1

# ── Python: misc utilities ────────────────────────────────────────────────────
RUN uv pip install \
    pillow numba librosa soundfile wandb optuna \
    rich click typer orjson python-dotenv \
    paramiko sympy networkx duckdb

# ── Python: dev tools ─────────────────────────────────────────────────────────
RUN uv pip install pytest ruff hatchling jupyter ipykernel

# ── Playwright browsers ───────────────────────────────────────────────────────
USER root
RUN playwright install --with-deps chromium
USER coder

# ── OCaml: install opam binary (needs root) ───────────────────────────────────
USER root
RUN bash -c 'echo /usr/local/bin | sh <(curl -fsSL https://opam.ocaml.org/install.sh) --no-backup'
USER coder

# ── OCaml: init + packages (as coder) ─────────────────────────────────────────
RUN opam init --disable-sandboxing --yes \
    && eval $(opam env) \
    && opam install --yes \
    dune menhir merlin ocaml-lsp-server odoc utop \
    lwt zarith hex uri alcotest cohttp-lwt-unix \
    cmdliner fmt logs ppx_deriving cstruct ctypes ctypes-foreign qcheck-core
ENV PATH="/home/coder/.opam/default/bin:${PATH}"
ENV OPAM_SWITCH_PREFIX="/home/coder/.opam/default"
ENV CAML_LD_LIBRARY_PATH="/home/coder/.opam/default/lib/stublibs"
ENV OCAML_TOPLEVEL_PATH="/home/coder/.opam/default/lib/toplevel"

# ── Go ─────────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:/home/coder/go/bin:${PATH}"

# ── Rust ───────────────────────────────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/home/coder/.cargo/bin:${PATH}"

# ── LaTeX + Pandoc (optional, ~900MB) ───────────────────────────────────────
USER root
RUN if [ "$WITH_LATEX" = "1" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            texlive texlive-latex-extra texlive-fonts-recommended \
            texlive-xetex latexmk pandoc \
        && rm -rf /var/lib/apt/lists/*; \
    fi
USER coder

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
