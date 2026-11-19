#!/usr/bin/env bash
set -euo pipefail

SECONDS=0

# ---------- Config (override any of these via environment variables) ----------
COMFY="${COMFY:-/app/ComfyUI}"
PIP="${PIP:-pip}"                       # e.g. PIP="/app/venv/bin/pip" if ComfyUI runs in a venv
HF_TOKEN="${HF_TOKEN:-}"                # REQUIRED: needed for the private LoRAs (Exnd/val)
MAX_JOBS="${MAX_JOBS:-6}"               # max simultaneous downloads
BASE=https://huggingface.co/Comfy-Org/Krea-2/resolve/main
STATS_DIR="$(mktemp -d)"                # each download writes the bytes it fetched here
trap 'rm -rf "$STATS_DIR"' EXIT

# ---------- Finish messages (picked by average download speed) ----------
# Nothing (or almost nothing) was downloaded
MSGS_CACHED=(
  "Barely anything to download. Either everything was cached or you're living in the future."
  "Cache hit! Your future self thanks your past self."
  "Models were already waiting for you. Nothing to do here, you're set."
  "Zero fluff, all cache. Your pod is a gremlin of efficiency."
  "Done before your coffee even started brewing."
)

# under 100 Mbps
MSGS_SLOW=(
  "Slow internet today, but every byte made it. Go make some art."
  "That connection took the scenic route. Worth the wait, though."
  "Patience paid off. Time to generate something beautiful."
  "Dial-up nostalgia unlocked, but the models arrived."
  "Slow and steady wins the render."
)

# 100 - 500 Mbps
MSGS_OK=(
  "Solid connection. Nothing fancy, nothing broken."
  "Decent speeds, decent vibes. Time to make some pixels."
  "Gigabytes were moved at a respectable pace. Your pod earned a snack."
  "Good things come to those who wait, and you didn't wait long."
  "Reliable, steady, slightly smug. Setup complete."
)

# 500 - 2000 Mbps
MSGS_FAST=(
  "That's a fast pipe. The internet was kind to you today."
  "Big files, small wait. Chef's kiss."
  "Speedy! Those models practically teleported in."
  "Smooth like butter. Go forth and create."
  "Fast enough to be slightly suspicious. Respect."
)

# over 2000 Mbps
MSGS_INSANE=(
  "Absolute rocket of a connection. Datacenter-grade speeds."
  "Speedrun complete. World record pace."
  "Gigabytes vanished into your disk like nothing. Wow."
  "That wasn't a download, that was a teleport."
  "Flash mode: engaged. Your pod is a beast."
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
  https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler
)

# ---------- Helpers ----------
fmt_time() { printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

pick() {
  local -n arr=$1
  echo "${arr[RANDOM % ${#arr[@]}]}"
}

if [ ! -d "$COMFY" ]; then
  echo "ERROR: ComfyUI folder not found at $COMFY"
  echo "Re-run with the correct path, e.g.:  COMFY=/path/to/ComfyUI bash setup.sh"
  exit 1
fi

# ---------- HF token check (STOPS the script if the token is missing or invalid) ----------
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
# Records how many bytes this call actually fetched (0 if the file was already there).
# Usage: dl URL DIR [SAVE_AS_FILENAME]
dl() {
  local url="$1" dir="$2" file="${3:-$(basename "$1")}" rc=0 before=0 after=0
  mkdir -p "$dir"
  [ -f "$dir/$file" ] && before=$(stat -c %s "$dir/$file")
  if command -v aria2c >/dev/null 2>&1; then
    local args=(-x 8 -s 8 -k 32M --file-allocation=none -c
      --summary-interval=10 --console-log-level=warn)
    [ -n "$HF_TOKEN" ] && args+=(--header="Authorization: Bearer $HF_TOKEN")
    aria2c "${args[@]}" -d "$dir" -o "$file" "$url" || rc=$?
  else
    local wargs=(-c)
    [ -n "$HF_TOKEN" ] && wargs+=(--header="Authorization: Bearer $HF_TOKEN")
    wget "${wargs[@]}" -O "$dir/$file" "$url" || rc=$?
  fi
  [ -f "$dir/$file" ] && after=$(stat -c %s "$dir/$file")
  echo $(( after - before )) > "$STATS_DIR/$BASHPID"
  return $rc
}

# Queue a download in the background, waiting if MAX_JOBS are already running
pids=()
queue() {
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do sleep 1; done
  dl "$@" &
  pids+=($!)
}

node_install() {
  local name
  name=$(basename "$1" .git)
  if [ -f "$COMFY/custom_nodes/$name/requirements.txt" ]; then
    $PIP install -q -r "$COMFY/custom_nodes/$name/requirements.txt" \
      || echo "WARNING: pip install failed for $name (check for dependency conflicts)"
  fi
}

# ---------- 1. Clone custom nodes (main branch) ----------
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes"
for url in "${NODES[@]}"; do
  name=$(basename "$url" .git)
  if [ -d "$name/.git" ]; then
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
PIP_PID=$!

# ---------- 3. Model downloads ----------
DL_START=$SECONDS

# Krea-2
queue "$BASE/diffusion_models/krea2_turbo_int8_convrot.safetensors" "$COMFY/models/diffusion_models"
queue "$BASE/loras/krea2_turbo_lora_rank_64_bf16.safetensors"       "$COMFY/models/loras"
queue "https://huggingface.co/thedeoxen/Krea-2-pose-controlnet/resolve/main/krea2_turbo_openpose_controlnet.safetensors" "$COMFY/models/loras"
queue "$BASE/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"       "$COMFY/models/text_encoders"
queue "$BASE/vae/qwen_image_vae.safetensors"                        "$COMFY/models/vae"
queue "https://huggingface.co/Comfy-Org/PixelDiT/resolve/main/text_encoders/gemma_2_2b_it_elm_bf16.safetensors" "$COMFY/models/text_encoders"
# PiD checkpoint, saved under a different filename than the URL
queue "https://huggingface.co/nvidia/PiD/resolve/main/checkpoints/PiD_v1pt5_res2kto4k_sr4x_official_qwenimage_distill_4step/model_ema_bf16.pth" "$COMFY/models/diffusion_models" "qwen_image_pid.pth"

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
queue "https://huggingface.co/Exnd/val/resolve/main/HM1Girl-V1-Krea.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/HMCumshot_V1.0.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/PenisV2_minimax-h3_epoch60.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/MM-H3%20-%20Blowjob%20v3.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/bounceV07-000230_Intense.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/bounceV07_fl2va-000230_Intense.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/HMNSFW-AIO-V2.5.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/zy_Amateur_Pov_H3.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/breast_size_v2_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/breast_fake_real_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/brightness_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/candid_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/detail_slider_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/nsfw_helper_slider_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/real_3d_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/wetness_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/zoom_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Exnd/val/resolve/main/ass_v2_krea2_loraholic.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/conradlocke/krea2-identity-edit/resolve/main/krea2_general_edit_v2.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/conradlocke/krea2-identity-edit/resolve/main/krea2_identity_edit_v2.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/fal/MiniMax-H3-Realism-People-LoRA/resolve/main/h3-realism-people-t2v-i2v-r2v.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Alissonerdx/Minimax-H3-ComfyUI/resolve/main/loras/minimax_h3_motion_transfer_tara_v1.0_ref2va.safetensors" "$COMFY/models/loras"
queue "https://huggingface.co/Quiho/Krea2_TextFusion_Refusal-Reduction_LoRA_v1.0_lora/resolve/main/Krea2_TextFusion_Refusal_Reduction.safetensors" "$COMFY/models/loras"


# ---------- 4. Wait for everything and report failures ----------
fail=0
for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
DL_ELAPSED=$(( SECONDS - DL_START ))
[ "$DL_ELAPSED" -lt 1 ] && DL_ELAPSED=1
wait "$PIP_PID" || fail=1
if [ "$fail" -ne 0 ]; then
  echo "One or more downloads failed after $(fmt_time $SECONDS). Re-run the script to resume."
  exit 1
fi

# ---------- 5. Finish line ----------
elapsed=$SECONDS
set +e   # the finish block must never kill the script silently

total_bytes=0
for f in "$STATS_DIR"/*; do
  if [ -f "$f" ]; then
    v=$(cat "$f" 2>/dev/null)
    total_bytes=$(( total_bytes + ${v:-0} ))
  fi
done

read -r size_gb speed_mbs speed_mbps < <(
  awk -v b="$total_bytes" -v t="$DL_ELAPSED" \
    'BEGIN{printf "%.2f %.1f %.0f", b/1e9, b/t/1e6, b*8/t/1e6}'
)
size_gb="${size_gb:-0}"; speed_mbs="${speed_mbs:-0}"; speed_mbps="${speed_mbps:-0}"

if   [ "$total_bytes" -lt 100000000 ]; then msg=$(pick MSGS_CACHED)   # < 100 MB fetched
elif [ "$speed_mbps" -lt 100 ];        then msg=$(pick MSGS_SLOW)
elif [ "$speed_mbps" -lt 500 ];        then msg=$(pick MSGS_OK)
elif [ "$speed_mbps" -lt 2000 ];       then msg=$(pick MSGS_FAST)
else                                        msg=$(pick MSGS_INSANE)
fi

echo ""
echo "=============================================="
echo "  Script finished in $(fmt_time $elapsed) (${elapsed}s total)"
echo "  Downloaded:    ${size_gb} GB in $(fmt_time $DL_ELAPSED)"
if [ "$total_bytes" -ge 100000000 ]; then
  echo "  Average speed: ${speed_mbs} MB/s (${speed_mbps} Mbps)"
fi
echo "  $msg"
echo "=============================================="
echo "Done. Restart ComfyUI to load the new nodes and models."
