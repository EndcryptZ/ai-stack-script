#!/usr/bin/env bash
set -euo pipefail

SECONDS=0

# ---------- Config (override any of these via environment variables) ----------
COMFY="${COMFY:-/app/ComfyUI}"
PIP="${PIP:-pip}"                       # e.g. PIP="/app/venv/bin/pip" if ComfyUI runs in a venv
HF_TOKEN="${HF_TOKEN:-}"                # optional: only needed for gated/private repos
BASE=https://huggingface.co/Comfy-Org/Krea-2/resolve/main

# ---------- Finish messages (10 per category) ----------
MSGS_FAST=(
  "Under 30 seconds?! Either everything was cached or you're living in the future."
  "Speedrun complete. World record pace."
  "That was so fast I think the models were already waiting for you."
  "Barely had time to blink. Blink-and-you-missed-it energy."
  "Flash mode: engaged. Nothing to do here, you're already set."
  "Faster than a microwave burrito. Respect."
  "Zero fluff, all speed. Your pod is a gremlin of efficiency."
  "Done before your coffee even started brewing."
  "Cache hit! Your future self thanks your past self."
  "Under 30 seconds. Somewhere, a sysadmin just smiled."
)

MSGS_MEDIUM=(
  "Under a minute. Just enough time to stretch. Nice."
  "Less than a minute, smooth like butter."
  "Quick and clean. Chef's kiss."
  "Almost a speedrun. Silver medal vibes."
  "A short stretch, a sip of water, and boom, ready to go."
  "Under a minute. Efficient and a little bit smug."
  "Not bad at all. The internet was kind to you today."
  "That was a lightning-ish round. Time to make some pixels."
  "Good vibes only. Setup done in under a minute."
  "Sleek. Swift. Slightly suspicious how easy that was."
)

MSGS_SLOW=(
  "Over a minute, but those models don't download themselves. Go make some art."
  "Big files, big dreams. Worth the wait."
  "Good things come to those who wait. Also to those with fast bandwidth."
  "Gigabytes were moved. Your pod earned a snack."
  "Patience paid off. Time to generate something beautiful."
  "That was a proper download session. You can feel the bytes."
  "Slow and steady wins the render."
  "Setup complete. Now go be an AI artist legend."
  "A little wait, a lot of models. Fair trade."
  "The pod has spoken: everything is installed. Go forth and create."
)

# ---------- Helpers ----------
fmt_time() { printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

pick() {
  local -n arr=$1
  echo "${arr[RANDOM % ${#arr[@]}]}"
}

# Sanity check: make sure ComfyUI is where we think it is
if [ ! -d "$COMFY" ]; then
  echo "ERROR: ComfyUI folder not found at $COMFY"
  echo "Re-run with the correct path, e.g.:  COMFY=/path/to/ComfyUI bash setup.sh"
  exit 1
fi

# Make sure aria2 is installed (falls back to wget if the install fails)
if ! command -v aria2c >/dev/null 2>&1; then
  SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  { $SUDO apt-get update -qq && $SUDO apt-get install -y -qq aria2; } \
    || echo "aria2 install failed, falling back to wget"
fi

# Download helper: multi-connection aria2c, no pre-allocation, resumable.
# Sends the HF token only if HF_TOKEN is set.
dl() {
  local url="$1" dir="$2" file
  file=$(basename "$url")
  mkdir -p "$dir"
  if command -v aria2c >/dev/null 2>&1; then
    local args=(-x 8 -s 8 -k 32M --file-allocation=none -c
      --summary-interval=10 --console-log-level=warn)
    [ -n "$HF_TOKEN" ] && args+=(--header="Authorization: Bearer $HF_TOKEN")
    aria2c "${args[@]}" -d "$dir" -o "$file" "$url"
  else
    local wargs=(-c)
    [ -n "$HF_TOKEN" ] && wargs+=(--header="Authorization: Bearer $HF_TOKEN")
    wget "${wargs[@]}" -O "$dir/$file" "$url"
  fi
}

# Custom node helper: clone if missing, install requirements if present.
# A failed pip install prints a warning instead of killing the whole script.
node() {
  local url="$1" name
  name=$(basename "$url" .git)
  [ -d "$name" ] || git clone -q "$url"
  if [ -f "$name/requirements.txt" ]; then
    $PIP install -q -r "$name/requirements.txt" \
      || echo "WARNING: pip install failed for $name (check for dependency conflicts)"
  fi
}

# ---------- 1. Model downloads (all in parallel, in the background) ----------
pids=()

# Krea-2
dl "$BASE/diffusion_models/krea2_turbo_int8_convrot.safetensors" "$COMFY/models/diffusion_models" & pids+=($!)
dl "$BASE/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"       "$COMFY/models/text_encoders"    & pids+=($!)
dl "$BASE/vae/qwen_image_vae.safetensors"                        "$COMFY/models/vae"              & pids+=($!)

# Flux.2 Klein 9B
dl "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"   "$COMFY/models/vae"              & pids+=($!)
dl "https://huggingface.co/Kiro930/flux-2-klein-9b/resolve/main/flux-2-klein-9b.safetensors"         "$COMFY/models/diffusion_models" & pids+=($!)
dl "https://huggingface.co/SassyDiffusion/FLUX.2-klein-9B-bf16/resolve/main/qwen_3_8b.safetensors"   "$COMFY/models/text_encoders"    & pids+=($!)

# Personal LoRAs (uncomment and edit once you pick a host, e.g. a private HF repo)
# dl "https://huggingface.co/yourname/my-loras/resolve/main/my_lora.safetensors" "$COMFY/models/loras" & pids+=($!)

# ---------- 2. Custom nodes (installed while the models download) ----------
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes"

node https://github.com/romandev-codex/ComfyUI-Downloader
node https://github.com/rgthree/rgthree-comfy
node https://github.com/WASasquatch/was-node-suite-comfyui
node https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes
node https://github.com/Jonseed/ComfyUI-Detail-Daemon
node https://github.com/1038lab/ComfyUI-RMBG
node https://github.com/MadiatorLabs/ComfyUI-RunpodDirect

# ---------- 3. Wait for downloads and report failures ----------
fail=0
for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
if [ "$fail" -ne 0 ]; then
  echo "One or more downloads failed after $(fmt_time $SECONDS). Re-run the script to resume."
  exit 1
fi

# ---------- 4. Finish line ----------
elapsed=$SECONDS
echo ""
echo "=============================================="
echo "  Script finished in $(fmt_time $elapsed) (${elapsed}s total)"
if [ "$elapsed" -lt 30 ]; then
  echo "  $(pick MSGS_FAST)"
elif [ "$elapsed" -lt 60 ]; then
  echo "  $(pick MSGS_MEDIUM)"
else
  echo "  $(pick MSGS_SLOW)"
fi
echo "=============================================="
echo "Done. Restart ComfyUI to load the new nodes and models."