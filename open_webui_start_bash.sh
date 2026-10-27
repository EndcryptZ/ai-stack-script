#!/usr/bin/env bash
# Installs Ollama + Open WebUI (port 3000) on a single RunPod pod,
# then starts each one in its own detached screen session.
set -euo pipefail

WEBUI_PORT=3000
OLLAMA_PORT=11434
DATA_ROOT=/workspace                      # RunPod persistent volume
OLLAMA_MODELS_DIR="$DATA_ROOT/ollama/models"
WEBUI_DATA_DIR="$DATA_ROOT/open-webui-data"
WEBUI_VENV="$DATA_ROOT/open-webui-venv"
MODEL="ttempvnn/DeepSeek-R1-Distill-Qwen-32B-abliterated-Q4-K-M:latest"

echo "==> [1/6] apt update + prerequisites"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y screen zstd curl ca-certificates

echo "==> [2/6] Installing Ollama"
curl -fsSL https://ollama.com/install.sh | sh

echo "==> [3/6] Installing Open WebUI (Python 3.11 via uv)"
# Open WebUI requires Python 3.11/3.12; uv fetches it without touching system Python
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

mkdir -p "$OLLAMA_MODELS_DIR" "$WEBUI_DATA_DIR"
if [ ! -d "$WEBUI_VENV" ]; then
  uv venv --python 3.11 "$WEBUI_VENV"
fi
uv pip install --python "$WEBUI_VENV/bin/python" open-webui

echo "==> [4/6] Starting Ollama in screen session 'ollama'"
if screen -list | grep -q "\.ollama"; then
  echo "    screen 'ollama' already running, skipping"
else
  screen -dmS ollama bash -c "
    export OLLAMA_MODELS='$OLLAMA_MODELS_DIR'
    export OLLAMA_HOST='127.0.0.1:$OLLAMA_PORT'
    ollama serve
    exec bash
  "
fi

# Wait for Ollama API to come up
echo "    waiting for Ollama API..."
OLLAMA_UP=0
for i in $(seq 1 60); do
  if curl -fs "http://127.0.0.1:$OLLAMA_PORT/api/version" >/dev/null 2>&1; then
    echo "    Ollama is up."
    OLLAMA_UP=1
    break
  fi
  sleep 1
done
if [ "$OLLAMA_UP" -ne 1 ]; then
  echo "ERROR: Ollama API did not come up. Check: screen -r ollama" >&2
  exit 1
fi

echo "==> [5/6] Pulling model: $MODEL"
OLLAMA_HOST="127.0.0.1:$OLLAMA_PORT" ollama pull "$MODEL"

echo "==> [6/6] Starting Open WebUI in screen session 'openwebui' on port $WEBUI_PORT"
if screen -list | grep -q "\.openwebui"; then
  echo "    screen 'openwebui' already running, skipping"
else
  screen -dmS openwebui bash -c "
    export DATA_DIR='$WEBUI_DATA_DIR'
    export OLLAMA_BASE_URL='http://127.0.0.1:$OLLAMA_PORT'
    '$WEBUI_VENV/bin/open-webui' serve --host 0.0.0.0 --port $WEBUI_PORT
    exec bash
  "
fi

echo
echo "Done. Active screen sessions:"
screen -list || true
echo
echo "Attach:  screen -r ollama   |   screen -r openwebui   (detach with Ctrl+A, then D)"
echo "Open WebUI: expose HTTP port $WEBUI_PORT on the pod, then use the RunPod proxy URL:"
echo "  https://<POD_ID>-$WEBUI_PORT.proxy.runpod.net"
echo "Run the model:  ollama run $MODEL"
