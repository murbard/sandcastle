#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Worker Setup ==="
echo ""

# --- 0. Preflight checks ---
errors=0

# Docker installed?
if command -v docker &>/dev/null; then
    echo "[ok] Docker is installed ($(docker --version | head -1))"
else
    echo "[!!] Docker is not installed. Install it first: https://docs.docker.com/engine/install/"
    errors=$((errors + 1))
fi

# Docker daemon running?
if docker info &>/dev/null 2>&1; then
    echo "[ok] Docker daemon is running"
else
    if id -nG "$USER" | grep -qw docker; then
        echo "[!!] Docker daemon is not running. Start it with: sudo systemctl start docker"
    else
        echo "[!!] Cannot connect to Docker. You may need to be in the 'docker' group:"
        echo "       sudo usermod -aG docker $USER"
        echo "     Then log out and back in (or run: newgrp docker)"
    fi
    errors=$((errors + 1))
fi

# Current user in docker group? (warn even if Docker works via sudo)
if id -nG "$USER" | grep -qw docker; then
    echo "[ok] User '$USER' is in the docker group"
else
    echo "[!]  User '$USER' is not in the 'docker' group."
    echo "     cw runs docker without sudo, so you likely need:"
    echo "       sudo usermod -aG docker $USER"
    echo "     Then log out and back in (or run: newgrp docker)"
    # Not fatal — Docker might work via socket permissions or rootless mode
fi

# git installed?
if command -v git &>/dev/null; then
    echo "[ok] git is installed"
else
    echo "[!!] git is not installed. Install it first: sudo apt install git"
    errors=$((errors + 1))
fi

# Claude CLI installed?
if command -v claude &>/dev/null; then
    echo "[ok] Claude CLI is installed"
else
    echo "[!]  Claude CLI not found on host (needed inside containers)"
    echo "     Install: npm install -g @anthropic-ai/claude-code"
fi

if [[ "$errors" -gt 0 ]]; then
    echo ""
    echo "Fix the errors above and re-run setup.sh"
    exit 1
fi
echo ""

# --- 1. OS user for defense in depth ---
if id claude-worker &>/dev/null; then
    echo "[ok] claude-worker user already exists"
else
    echo "[+] Creating claude-worker user..."
    sudo useradd -m -s /usr/sbin/nologin claude-worker
    sudo usermod -aG docker claude-worker 2>/dev/null || true
    echo "[ok] claude-worker user created"
fi

# --- 2. ulimits ---
LIMITS_FILE="/etc/security/limits.d/claude-worker.conf"
if [[ -f "$LIMITS_FILE" ]]; then
    echo "[ok] ulimits already configured"
else
    echo "[+] Configuring ulimits..."
    sudo tee "$LIMITS_FILE" > /dev/null <<'EOF'
claude-worker  hard  nproc    512
claude-worker  hard  nofile   4096
claude-worker  hard  as       8388608
EOF
    echo "[ok] ulimits configured at ${LIMITS_FILE}"
fi

# --- 3. GitHub token storage ---
TOKEN_DIR="$HOME/.claude-worker"
TOKEN_FILE="$TOKEN_DIR/github-token"
mkdir -p "$TOKEN_DIR"
chmod 700 "$TOKEN_DIR"

if [[ -f "$TOKEN_FILE" ]]; then
    echo "[ok] GitHub token file exists at ${TOKEN_FILE}"
else
    echo ""
    echo "--- GitHub Token Setup ---"
    echo "Create a fine-grained PAT at: https://github.com/settings/personal-access-tokens/new"
    echo ""
    echo "Recommended scopes:"
    echo "  - Repository access: Only select repositories (pick your repos)"
    echo "  - Contents: Read and write  (push branches)"
    echo "  - Pull requests: Read and write  (create PRs)"
    echo "  - Metadata: Read  (required)"
    echo ""
    echo "Then enable branch protection on your repos:"
    echo "  - Require PR for merges to main"
    echo "  - Require at least 1 approving review"
    echo ""
    read -rsp "Paste your GitHub token (hidden): " token
    echo ""
    if [[ -n "$token" ]]; then
        echo "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        echo "[ok] Token saved to ${TOKEN_FILE}"
    else
        echo "[skip] No token provided. You can save it later to ${TOKEN_FILE}"
    fi
fi

# --- 4. Install cw command (before docker build so it's available even if build fails) ---
echo ""
echo "[+] Installing cw command..."
chmod +x "${SCRIPT_DIR}/cw"

mkdir -p "$HOME/.local/bin"
ln -sf "${SCRIPT_DIR}/cw" "$HOME/.local/bin/cw"

if echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo "[ok] cw installed to ~/.local/bin/cw"
else
    echo "[ok] cw symlinked to ~/.local/bin/cw"
    echo "[!]  ~/.local/bin is not on your PATH. Add it:"
    echo '       echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc && source ~/.bashrc'
fi

# --- 5. Build Docker image ---
echo ""
echo "[+] Building Docker image (this may take a while on first run)..."
docker build \
    --build-arg USER_UID="$(id -u)" \
    --build-arg USER_GID="$(id -g)" \
    -t claude-worker:latest \
    "$SCRIPT_DIR"
echo "[ok] Docker image built: claude-worker:latest"

# --- 6. Verify Claude auth ---
echo ""
if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    echo "[ok] Claude OAuth credentials found"
else
    echo "[!]  No Claude credentials found at ~/.claude/.credentials.json"
    echo "     Run 'claude' on the host first to log in with your plan."
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Usage:"
echo "  cw new myproject ~/src/myproject   # Create a new container + start Claude"
echo "  cw new myproject ~/src/myproject 'fix the login bug'"
echo "  cw attach myproject                # Re-attach to existing container"
echo "  cw ls                              # List all cw containers"
echo "  cw rm myproject                    # Remove a container"
echo "  cw rebuild                         # Rebuild the Docker image"
