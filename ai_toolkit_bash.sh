#!/usr/bin/env bash
# Auto-installer for ostris/ai-toolkit in /workspace
set -euo pipefail

WORKSPACE="/workspace"
INSTALL_DIR="$WORKSPACE/ai-toolkit"
VENV_DIR="$INSTALL_DIR/venv"

echo "==> Installing system dependencies"
if command -v apt-get >/dev/null 2>&1; then
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO apt-get update -y
    $SUDO apt-get install -y git python3 python3-venv python3-pip build-essential curl
fi

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo "==> Cloning ai-toolkit"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only
else
    git clone https://github.com/ostris/ai-toolkit.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
git submodule update --init --recursive

echo "==> Creating virtual environment"
[ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --upgrade pip wheel setuptools

echo "==> Installing PyTorch (CUDA 12.6)"
pip install --no-cache-dir \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu126

echo "==> Installing ai-toolkit requirements"
pip install --no-cache-dir -r requirements.txt

# Optional: Hugging Face token for gated models (e.g. FLUX.1-dev)
if [ -n "${HF_TOKEN:-}" ]; then
    echo "HF_TOKEN=$HF_TOKEN" > "$INSTALL_DIR/.env"
    echo "==> Saved HF_TOKEN to $INSTALL_DIR/.env"
fi

# Optional: install Node.js so the web UI can run
if ! command -v node >/dev/null 2>&1; then
    echo "==> Installing Node.js 20 for the UI"
    curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO:-} bash -
    ${SUDO:-} apt-get install -y nodejs
fi

echo
echo "==> Done! ai-toolkit installed at $INSTALL_DIR"
echo "    Activate env:  source $VENV_DIR/bin/activate"
echo "    Run a job:     cd $INSTALL_DIR && python run.py config/your_config.yaml"

echo "==> Starting ai-toolkit UI in a screen session"
command -v screen >/dev/null 2>&1 || ${SUDO:-} apt-get install -y screen
screen -S ai-toolkit -X quit >/dev/null 2>&1 || true
screen -dmS ai-toolkit bash -c "cd $INSTALL_DIR && source $VENV_DIR/bin/activate && cd ui && npm run build_and_start"
echo "    UI is starting on port 8675 (first build can take a minute or two)"
echo "    Attach to it with: screen -r ai-toolkit   (detach with Ctrl+A then D)"
