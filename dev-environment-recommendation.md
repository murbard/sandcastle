# Swiss-Army-Knife Dev Environment: Recommended Base Image

Based on an audit of 65 GitHub repositories spanning Python, OCaml, C/C++, JavaScript/TypeScript, Rust, and Cairo.

## Base Image

**Latest Ubuntu LTS** -- broad package support, stable, well-understood. Use as the foundation rather than Alpine (glibc compatibility matters for Python scientific packages and OCaml).

---

## Python (primary language -- ~40 repos)

### Runtime & Tooling

| Tool | Rationale |
|------|-----------|
| Latest Python | Via uv -- it manages Python versions, so just need uv bootstrapped |
| **uv** | Primary package/project manager (migrated from Poetry) |
| pip | Fallback, still needed occasionally |
| hatchling | Build backend for newer projects |
| pytest | Test framework |
| ruff | Linter + formatter |
| jupyter / ipykernel | For notebook-based ML work (nanoGPT, Face-Depixelizer) |

### Core Packages (pre-install into a default venv or system Python)

**Numerical / ML (the heavy hitters -- worth pre-installing to save build time):**

| Package | Usage |
|---------|-------|
| torch + torchvision + torchaudio | Primary DL framework (10+ repos) |
| numpy | Ubiquitous |
| scipy | Scientific computing |
| scikit-learn | Classical ML |
| matplotlib | Plotting |
| pandas | Data manipulation |
| tqdm | Progress bars |

**LLM / AI APIs:**

| Package | Usage |
|---------|-------|
| openai | 4 repos |
| anthropic | 1 repo, likely growing |
| tiktoken | Tokenizer |
| transformers | HuggingFace models |
| datasets | HuggingFace data loading |

**Web / HTTP / Scraping:**

| Package | Usage |
|---------|-------|
| requests | HTTP client |
| beautifulsoup4 | HTML parsing |
| flask | Lightweight web framework |
| gunicorn | WSGI server |
| pydantic | Data validation |

**Crypto / Blockchain:**

| Package | Usage |
|---------|-------|
| pysodium | Libsodium bindings |
| fastecdsa | Elliptic curves |
| secp256k1 | Bitcoin curve |

**Misc useful:**

| Package | Usage |
|---------|-------|
| pillow | Image processing |
| numba | JIT compilation |
| librosa + soundfile | Audio processing |
| wandb | Experiment tracking |
| optuna | Hyperparameter optimization |

---

## OCaml (second language -- 8+ repos, including large Tezos codebase)

### Runtime & Tooling

| Tool | Rationale |
|------|-----------|
| **opam** | Package manager |
| OCaml compiler | Latest stable via opam |
| **dune** | Build system (all repos use it) |
| **menhir** | Parser generator |
| **merlin** | Editor support / type info |
| ocaml-lsp-server | LSP for editors |
| odoc | Documentation |
| utop | Interactive REPL |

### Key Libraries (pre-install via opam)

| Library | Purpose |
|---------|---------|
| lwt | Async/cooperative threading |
| zarith | Arbitrary precision arithmetic |
| hex | Hex encoding |
| uri | URI handling |
| alcotest | Testing |
| cohttp-lwt-unix | HTTP client/server |
| cmdliner | CLI argument parsing |
| fmt, logs | Formatting, logging |
| ppx_deriving | Deriving boilerplate |
| cstruct | C-compatible structs |
| ctypes + ctypes-foreign | C FFI |
| qcheck-core | Property-based testing |

---

## JavaScript / TypeScript

### Runtime & Tooling

| Tool | Rationale |
|------|-----------|
| **Node.js LTS** | Runtime |
| **npm** | Package manager |
| **pnpm** | Alternative, increasingly common |
| **TypeScript** | Used in quimby and others |
| **esbuild** | Fast bundler |

No need to pre-install JS packages globally -- `npm install` is fast enough. Just ensure the runtimes are present.

---

## C / C++

| Tool | Rationale |
|------|-----------|
| gcc + g++ | Compiler |
| clang + clang++ | Alternative compiler |
| make | Build tool |
| cmake | Build system (general-purpose) |
| gdb | Debugger |
| valgrind | Memory analysis |
| pkg-config | Library discovery |
| libsodium-dev | Crypto library (used by pysodium, OCaml crypto) |
| libgmp-dev | Big integers (needed by zarith, secp256k1) |
| libffi-dev | FFI (needed by ctypes, Python cffi) |

---

## Rust

No active Rust projects currently, but `ex.rs` exists and the Tezos codebase contains Rust components.

| Tool | Rationale |
|------|-----------|
| rustup + stable toolchain | Standard installer |
| cargo | Build system / package manager |
| wasm32-unknown-unknown target | WebAssembly target (Tezos uses WASM) |

Minimal install -- just the toolchain. No need for pre-installed crates.

---

## Cairo / Starknet

| Tool | Rationale |
|------|-----------|
| **Scarb** | Cairo package manager (used in stark_sig) |

Low priority -- single repo. Include only if image size isn't a concern.

---

## General CLI Tools

| Tool | Purpose |
|------|---------|
| git | Version control |
| gh | GitHub CLI |
| curl, wget | HTTP fetching |
| jq | JSON processing |
| ripgrep (rg) | Fast search |
| fd-find | Fast file finder |
| tmux | Terminal multiplexer |
| htop | Process monitor |
| docker CLI | Container management (for DinD or socket mount) |
| sqlite3 | Lightweight DB |
| postgresql-client | psql for connecting to Postgres |
| redis-tools | redis-cli |
| ssh, scp | Remote access |
| unzip, tar, gzip, xz | Archive tools |

---

## Summary by Priority

### Tier 1 -- Must have
- Latest Python + uv + PyTorch stack + core scientific packages
- Latest OCaml + opam + dune + core libraries
- Node.js LTS + npm + TypeScript
- gcc/g++/clang + make + cmake
- git, gh, curl, jq, ripgrep

### Tier 2 -- Should have
- Rust toolchain (rustup + stable)
- Jupyter
- LLM client libraries (openai, anthropic)
- libsodium, libgmp, libffi (needed as build deps by several projects)
- tmux, htop, fd-find

### Tier 3 -- Nice to have
- Scarb (Cairo)
- redis-tools, postgresql-client
- valgrind, gdb
- wasm32 Rust target

---

## Estimated Image Size

Expect **8-12 GB** compressed. The bulk comes from:
- PyTorch with CUDA support: ~4-5 GB
- OCaml switch + packages: ~1-2 GB
- Rust toolchain: ~1 GB
- Node.js + system packages: ~1 GB
- Base OS + CLI tools: ~500 MB

If CUDA isn't needed (CPU-only PyTorch), the image drops to **4-6 GB**.

Consider a multi-stage or layered approach where the PyTorch/CUDA layer is optional.
