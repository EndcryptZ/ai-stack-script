#!/usr/bin/env bash
# Installs ostris/ai-toolkit in /workspace and auto-starts the UI (port 8675)
set -euo pipefail

WORKSPACE="/workspace"
INSTALL_DIR="$WORKSPACE/ai-toolkit"
VENV_DIR="$INSTALL_DIR/venv"
LOG_FILE="$INSTALL_DIR/ui.log"
SESSION="ai-toolkit"
UI_PORT=8675

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

echo "==> Installing system dependencies"
if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y git python3 python3-venv python3-pip build-essential curl screen
fi

# Prefer python3.12 if available, otherwise fall back to python3 (needs >= 3.10)
PYTHON_BIN="python3"
command -v python3.12 >/dev/null 2>&1 && PYTHON_BIN="python3.12"
if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    echo "ERROR: Python >= 3.10 is required (found: $("$PYTHON_BIN" --version 2>&1))" >&2
    exit 1
fi
echo "    Using $("$PYTHON_BIN" --version)"

echo "==> Cloning ai-toolkit"
mkdir -p "$WORKSPACE"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only
else
    git clone https://github.com/ostris/ai-toolkit.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

echo "==> Creating virtual environment"
[ -d "$VENV_DIR" ] || "$PYTHON_BIN" -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "==> Upgrading pip and pre-installing typing_extensions from PyPI"
# The PyTorch index doesn't carry every dependency, so grab these from PyPI first
pip3 install --upgrade pip setuptools wheel
pip3 install "typing_extensions>=4.10.0"

echo "==> Installing PyTorch (CUDA 13.0)"
pip3 install --no-cache-dir \
    torch==2.13.0 torchvision==0.28.0 torchaudio==2.11.0 \
    --index-url https://download.pytorch.org/whl/cu130

echo "==> Installing requirements"
pip3 install -r requirements.txt

# Node.js > 20 is needed for the UI
NODE_MAJOR=0
command -v node >/dev/null 2>&1 && NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 21 ]; then
    echo "==> Installing Node.js 22 (found major version: $NODE_MAJOR)"
    curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO bash -
    $SUDO apt-get install -y nodejs
fi
echo "    Using node $(node -v), npm $(npm -v)"

echo "==> Starting UI in screen session '$SESSION'"
screen -S "$SESSION" -X quit >/dev/null 2>&1 || true
: > "$LOG_FILE"
screen -dmS "$SESSION" bash -c "cd $INSTALL_DIR && source $VENV_DIR/bin/activate && cd ui && npm run build_and_start 2>&1 | tee $LOG_FILE; echo; echo 'UI process exited. See $LOG_FILE'; exec bash"

echo "==> Waiting for UI on port $UI_PORT (first build can take a few minutes)"
for i in $(seq 1 90); do
    if curl -fs -o /dev/null "http://localhost:$UI_PORT"; then
        echo "    UI is up!"
        break
    fi
    sleep 5
    if [ "$i" -eq 90 ]; then
        echo "    UI did not respond within 7.5 minutes. Last log lines:"
        tail -n 20 "$LOG_FILE" || true
    fi
done

echo
screen -ls || true
echo
echo "==> Done"
echo "    UI:      http://localhost:$UI_PORT  (or http://<your-ip>:$UI_PORT on a server)"
echo "    Attach:  screen -r $SESSION   (detach with Ctrl+A then D)"
echo "    Log:     $LOG_FILE"
