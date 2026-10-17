#!/usr/bin/env bash
set -euo pipefail

SECONDS=0

# ---------- Config (override any of these via environment variables) ----------
COMFY="${COMFY:-/app/ComfyUI}"
PIP="${PIP:-pip}"                       # e.g. PIP="/app/venv/bin/pip" if ComfyUI runs in a venv
HF_TOKEN="${HF_TOKEN:-}"                # REQUIRED: needed for the private LoRAs (Exnd/val); script stops if invalid
MAX_JOBS="${MAX_JOBS:-6}"               # max simultaneous downloads
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

# ---------- Custom nodes (all cloned from their main branch) ----------
NODES=(
  https://github.com/romandev-codex/ComfyUI-Downloader
  https://github.com/rgthree/rgthree-comfy
  https://github.com/WASasquatch/was-node-suite-comfyui
  https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes
  https://github.com/Jonseed/ComfyUI-Detail-Daemon
  https://github.com/1038lab/ComfyUI-RMBG
  https://github.com/MadiatorLabs/ComfyUI-RunpodDirect
  https://github.com/kijai/ComfyUI-KJNodes
  https://github.com/kosinkadink/ComfyUI-VideoHelperSuite
  https://github.com/Fannovel16/comfyui_controlnet_aux
  https://github.com/Fannovel16/ComfyUI-Frame-Interpolation
  https://github.com/kijai/ComfyUI-segment-anything-2
  https://github.com/kijai/ComfyUI-WanAnimatePreprocess
  https://github.com/kijai/ComfyUI-WanVideoWrapper
  https://github.com/chrisgoringe/cg-use-everywhere
  https://github.com/yolain/Comfyui-Easy-Use
  https://github.com/ostris/ComfyUI-Krea2-Ostris-Edit
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

# ---------- HF token check (STOPS the script if the token is missing or invalid) ----------
# Prompt from the terminal (works even when the script is piped into bash)
if [ -z "$HF_TOKEN" ]; then
  { read -rsp "Enter your HF token: " HF_TOKEN </dev/tty; echo; } 2>/dev/null || true
fi
if [ -z "$HF_TOKEN" ]; then
  echo "ERROR: no HF token provided. It is required to download the private LoRAs."
  exit 1
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
  -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami-v2 || true)
if [ "$code" != "200" ]; then
  echo "ERROR: HF token is invalid or could not be verified (HTTP ${code:-none}). Stopping."
  exit 1
fi

# Make sure the token can actually reach the private LoRA repo (302 = redirect to the file = OK)
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -I \
  -H "Authorization: Bearer $HF_TOKEN" \
  "https://huggingface.co/Exnd/val/resolve/main/val_alvarez.safetensors" || true)
case "$code" in
  200|302) echo "HF token OK, private repo accessible." ;;
  *)
    echo "ERROR: token is valid but can't access Exnd/val (HTTP ${code:-none}). Stopping."
    exit 1 ;;
esac

# Make sure aria2 is installed (falls back to wget if the install fails)
if ! command -v aria2c >/dev/null 2>&1; then
  SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
  { $SUDO apt-get update -qq && $SUDO apt-get install -y -qq aria2; } \
    || echo "aria2 install failed, falling back to wget"
fi

# Download helper: multi-connection aria2c, no pre-allocation, resumable.
# Usage: dl URL DIR [SAVE_AS_FILENAME]   (filename defaults to the one in the URL)
# Sends the (already validated) HF token with every request.
dl() {
  local url="$1" dir="$2" file="${3:-$(basename "$1")}"
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

# Queue a download in the background, waiting if MAX_JOBS are already running
pids=()
queue() {
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do sleep 1; done
  dl "$@" &
  pids+=($!)
}

# Install a custom node's requirements. A failure prints a warning instead of stopping the script.
node_install() {
  local name
  name=$(basename "$1" .git)
  if [ -f "$COMFY/custom_nodes/$name/requirements.txt" ]; then
    $PIP install -q -r "$COMFY/custom_nodes/$name/requirements.txt" \
      || echo "WARNING: pip install failed for $name (check for dependency conflicts)"
  fi
}

# ---------- 1. Clone custom nodes FIRST, always on the main branch (some model files live inside node folders) ----------
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes"
for url in "${NODES[@]}"; do
  name=$(basename "$url" .git)
  if [ -d "$name/.git" ]; then
    # Already cloned: switch to main and update to the latest commit
    git -C "$name" fetch -q origin main \
      && git -C "$name" checkout -q -B main origin/main \
      || echo "WARNING: couldn't update $name to main"
  elif [ -d "$name" ]; then
    echo "WARNING: $name exists but isn't a git clone (registry/zip install?); skipping. Delete it to get main."
  else
    git clone -q -b main "$url" || echo "WARNING: clone failed for $name (main)"
  fi
done

# ---------- 2. pip installs run in the background while models download ----------
(
  for url in "${NODES[@]}"; do node_install "$url"; done
) &
pids+=($!)

# ---------- 3. Model downloads (queued, up to MAX_JOBS at a time) ----------

# Krea-2
queue "$BASE/diffusion_models/krea2_turbo_int8_convrot.safetensors" "$COMFY/models/diffusion_models"
queue "$BASE/loras/krea2_turbo_lora_rank_64_bf16.safetensors"       "$COMFY/models/loras"
queue "https://huggingface.co/thedeoxen/Krea-2-pose-controlnet/resolve/main/krea2_turbo_openpose_controlnet.safetensors" "$COMFY/models/loras"
queue "$BASE/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"       "$COMFY/models/text_encoders"
queue "$BASE/vae/qwen_image_vae.safetensors"                        "$COMFY/models/vae"
queue "https://huggingface.co/Comfy-Org/PixelDiT/resolve/main/text_encoders/gemma_2_2b_it_elm_bf16.safetensors" "$COMFY/models/text_encoders"
# PiD checkpoint, saved under the filename you specified (differs from the filename in the URL)
queue "https://huggingface.co/nvidia/PiD/resolve/main/checkpoints/PiD_v1pt5_res2kto4k_sr4x_official_qwenimage_distill_4step/model_ema_bf16.pth" "$COMFY/models/diffusion_models" "qwen_image_pid.pth"

# Flux.2 Klein 9B
queue "https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"   "$COMFY/models/vae"
queue "https://huggingface.co/Kiro930/flux-2-klein-9b/resolve/main/flux-2-klein-9b.safetensors"         "$COMFY/models/diffusion_models"
queue "https://huggingface.co/SassyDiffusion/FLUX.2-klein-9B-bf16/resolve/main/qwen_3_8b.safetensors"   "$COMFY/models/text_encoders"

# Wan 2.1 / SCAIL-2 (also shared with Wan 2.2 Animate: clip_vision_h, umt5, wan_2.1_vae)
queue "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"                "$COMFY/models/clip_vision"
queue "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"           "$COMFY/models/loras"
queue "https://huggingface.co/Comfy-Org/sam3.1/resolve/main/checkpoints/sam3.1_multiplex_fp16.safetensors"                                         "$COMFY/models/checkpoints"
queue "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"  "$COMFY/models/text_encoders"
queue "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"                           "$COMFY/models/vae"
queue "https://huggingface.co/Comfy-Org/SCAIL-2/resolve/main/diffusion_models/wan2.1_14B_SCAIL_2_int8_convrot.safetensors"                         "$COMFY/models/diffusion_models"

# MiniMax-H3
queue "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors"      "$COMFY/models/diffusion_models"
queue "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors"   "$COMFY/models/text_encoders"
queue "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors"                       "$COMFY/models/vae"
queue "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors"                       "$COMFY/models/vae"
queue "https://huggingface.co/Kijai/MiniMax-H3-TAE/resolve/main/vae_approx/taeh3.safetensors"                                    "$COMFY/models/vae_approx"
queue "https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors" "$COMFY/models/loras"

# Wan 2.2 Animate
queue "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_int8_convrot.safetensors" "$COMFY/models/diffusion_models"
queue "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors"       "$COMFY/models/loras"
# Saved under the filename your workflow expects (differs from the filename in the URL)
queue "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors"          "$COMFY/models/loras" "i2v_lightx2v_low_noise_model.safetensors"

# Pose / detection / segmentation / interpolation
queue "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx"        "$COMFY/models/detection"
queue "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin"          "$COMFY/models/detection"
queue "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$COMFY/models/detection"
queue "https://huggingface.co/Kijai/sam2-safetensors/resolve/main/sam2.1_hiera_base_plus.safetensors"      "$COMFY/models/sam2"
queue "https://huggingface.co/hr16/DWPose-TorchScript-BatchSize5/resolve/main/dw-ll_ucoco_384_bs5.torchscript.pt" "$COMFY/custom_nodes/comfyui_controlnet_aux/ckpts/hr16/DWPose-TorchScript-BatchSize5"
queue "https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx"                                      "$COMFY/custom_nodes/comfyui_controlnet_aux/ckpts/yzd-v/DWPose"
queue "https://huggingface.co/MachineDelusions/RIFE/resolve/main/rife49.pth"                               "$COMFY/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife"

# Personal LoRAs (private HF repo, token validated at the top of the script)
queue "https://huggingface.co/Exnd/val/resolve/main/val_alvarez.safetensors"      "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_alvarez_nsfw.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final_000001500.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final_000001750.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final_000002000.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final_000002250.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final_000002500.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/val_final_000002750.safetensors" "$COMFY/models/loras"

# ---------- 4. Wait for everything and report failures ----------
fail=0
for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
if [ "$fail" -ne 0 ]; then
  echo "One or more downloads failed after $(fmt_time $SECONDS). Re-run the script to resume."
  exit 1
fi

# ---------- 5. Finish line ----------
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
