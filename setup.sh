#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Worker Setup ==="
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

# --- 4. Build Docker image ---
echo ""
echo "[+] Building Docker image..."
docker build \
    --build-arg USER_UID="$(id -u)" \
    --build-arg USER_GID="$(id -g)" \
    -t claude-worker:latest \
    "$SCRIPT_DIR"
echo "[ok] Docker image built: claude-worker:latest"

# --- 5. Install cw command ---
echo ""
echo "[+] Installing cw command..."
chmod +x "${SCRIPT_DIR}/cw"

# Symlink to ~/.local/bin (no sudo needed)
mkdir -p "$HOME/.local/bin"
ln -sf "${SCRIPT_DIR}/cw" "$HOME/.local/bin/cw"

# Check if ~/.local/bin is on PATH
if echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo "[ok] cw installed to ~/.local/bin/cw"
else
    echo "[ok] cw installed to ~/.local/bin/cw"
    echo "[!] Add ~/.local/bin to your PATH:"
    echo '    echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
fi

# --- 6. Verify Claude auth ---
echo ""
if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    echo "[ok] Claude OAuth credentials found"
else
    echo "[!] No Claude credentials found at ~/.claude/.credentials.json"
    echo "    Run 'claude' on the host first to log in with your plan."
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Usage:"
echo "  cw new myproject               # Create a new container + start Claude"
echo "  cw new myproject 'fix bug'     # Start with a prompt"
echo "  cw attach myproject            # Re-attach to existing container"
echo "  cw ls                          # List all cw containers"
echo "  cw rm myproject                # Remove a container"
echo "  cw rm --all                    # Remove all stopped containers"
echo "  cw rebuild                     # Rebuild the Docker image"
echo ""
echo "Your tmux workflow:"
echo "  1. tmux new -s work"
echo "  2. cw new myproject            # Pane 1"
echo "  3. Ctrl-B %  →  cw new other  # Pane 2 (split)"
echo "  4. Exit claude, come back with 'cw attach myproject'"
