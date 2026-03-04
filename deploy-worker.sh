#!/usr/bin/env bash
# =============================================================================
# deploy-worker.sh — Provision and manage a Vast.ai GPU instance for ComfyUI
# =============================================================================
#
# Usage:
#   ./deploy-worker.sh up        Search offers, launch instance with ComfyUI
#   ./deploy-worker.sh down      Destroy the instance (irreversible)
#   ./deploy-worker.sh stop      Stop the instance (preserves data)
#   ./deploy-worker.sh start     Start a previously stopped instance
#   ./deploy-worker.sh status    Show instance state and info
#   ./deploy-worker.sh ssh       SSH into the instance
#   ./deploy-worker.sh tunnel    SSH tunnel — ComfyUI at http://localhost:8188
#   ./deploy-worker.sh logs      Show instance logs
#
# Prerequisites:
#   - vastai CLI installed (pip install vastai)
#   - API key configured  (vastai set api-key YOUR_KEY)
#   - jq installed         (brew install jq)
#
# Configuration: .env (secrets) then infra/worker.conf (deploy overrides).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/infra"
CONF_FILE="${CONF_DIR}/worker.conf"
ONSTART_FILE="${CONF_DIR}/onstart.sh"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Defaults (overridden by .env and worker.conf) ─────────────────────────────

TEMPLATE_HASH="${TEMPLATE_HASH:-f3fbe8736dd0645619432c664c90d7c7}"
GPU_MIN_RAM="${GPU_MIN_RAM:-24}"
GPU_NAME="${GPU_NAME:-}"
DISK_SIZE="${DISK_SIZE:-200}"
MAX_PRICE="${MAX_PRICE:-}"
INSTANCE_LABEL="lpf-worker"
HF_TOKEN="${HF_TOKEN:-}"

# ── Load config: .env first (secrets), then worker.conf (overrides) ───────────

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_API_KEY:-}}"
fi
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
    HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_API_KEY:-}}"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf "\033[36m[lpf]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[lpf]\033[0m %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required but not installed."
}

# SSH options for temporary Vast.ai instances (do not persist host keys)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# ── Find instance by label ──────────────────────────────────────────────────

find_instance() {
    vastai show instances --raw 2>/dev/null \
        | jq -r ".[] | select(.label == \"${INSTANCE_LABEL}\")" 2>/dev/null
}

get_instance_id() {
    find_instance | jq -r '.id // empty' | head -1
}

get_instance_status() {
    find_instance | jq -r '.actual_status // .intended_status // empty' | head -1
}

get_ssh_info() {
    local id="$1"
    vastai ssh-url "$id" 2>/dev/null
}

# Parse host and port from ssh-url output.
# Vast.ai may return either "ssh -p PORT root@HOST" or "ssh://root@HOST:PORT".
parse_ssh_host() {
    local ssh_url="$1"
    echo "$ssh_url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

parse_ssh_port() {
    local ssh_url="$1"
    # Try "ssh -p PORT ..." first, then "ssh://...HOST:PORT" (port after last colon)
    echo "$ssh_url" | sed -E 's/.*-p ([0-9]+).*/\1/; s/.*:([0-9]+)$/\1/' | grep -E '^[0-9]+$' | head -1
}

wait_for_ready() {
    local id="$1" timeout_secs="${2:-300}" elapsed=0
    log "Waiting for instance ${id} to be ready..."
    while true; do
        local status
        status=$(vastai show instance "$id" --raw 2>/dev/null | jq -r '.actual_status // empty')
        if [[ "$status" == "running" ]]; then
            log "Instance is running."
            return 0
        fi
        if (( elapsed >= timeout_secs )); then
            die "Timed out waiting for instance to be ready (status: ${status})."
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
}

# ── Build onstart command ───────────────────────────────────────────────────

build_onstart_cmd() {
    if [[ -f "$ONSTART_FILE" ]]; then
        cat "$ONSTART_FILE"
    else
        cat << 'ONSTART'
#!/bin/bash
COMFY_DIR="/workspace/ComfyUI"
LTX_DIR="${COMFY_DIR}/custom_nodes/ComfyUI-LTXVideo"
if [ ! -d "$LTX_DIR" ]; then
    cd "${COMFY_DIR}/custom_nodes"
    git clone --depth 1 https://github.com/Lightricks/ComfyUI-LTXVideo.git
    cd ComfyUI-LTXVideo
    pip install -r requirements.txt
fi
ONSTART
    fi
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_up() {
    require_cmd vastai
    require_cmd jq

    local existing_id
    existing_id=$(get_instance_id)
    if [[ -n "$existing_id" ]]; then
        local status
        status=$(get_instance_status)
        if [[ "$status" == "running" ]]; then
            log "Instance ${existing_id} is already running."
            cmd_status
            return 0
        else
            log "Instance ${existing_id} exists (status: ${status}). Starting it..."
            cmd_start
            return 0
        fi
    fi

    # Build search query
    local query="gpu_ram>=${GPU_MIN_RAM} num_gpus=1 disk_space>=${DISK_SIZE} inet_down>200 direct_port_count>3 reliability>0.95 rentable=true"
    if [[ -n "$GPU_NAME" ]]; then
        query="${query} gpu_name=${GPU_NAME}"
    fi

    log "Searching for GPU offers..."
    log "  Query: ${query}"

    local offers
    offers=$(vastai search offers "${query}" -o 'dph_total' --raw 2>/dev/null)

    if [[ -z "$offers" || "$offers" == "[]" ]]; then
        die "No offers found matching your criteria. Try relaxing GPU_MIN_RAM, DISK_SIZE, or GPU_NAME."
    fi

    # Apply price filter if set
    local offer
    if [[ -n "$MAX_PRICE" ]]; then
        offer=$(echo "$offers" | jq -r "[.[] | select(.dph_total <= ${MAX_PRICE})] | first // empty")
        if [[ -z "$offer" ]]; then
            die "No offers found under \$${MAX_PRICE}/hr. Cheapest available: \$$(echo "$offers" | jq -r '.[0].dph_total')/hr"
        fi
    else
        offer=$(echo "$offers" | jq -r '.[0] // empty')
    fi

    local offer_id gpu_name gpu_ram dph
    offer_id=$(echo "$offer" | jq -r '.id')
    gpu_name=$(echo "$offer" | jq -r '.gpu_name')
    gpu_ram=$(echo "$offer" | jq -r '.gpu_ram')
    dph=$(echo "$offer" | jq -r '.dph_total')

    log "Selected offer:"
    log "  ID:    ${offer_id}"
    log "  GPU:   ${gpu_name} (${gpu_ram}GB VRAM)"
    log "  Price: \$${dph}/hr"

    # Build env flags
    local env_args="-p 8188:8188"
    if [[ -n "$HF_TOKEN" ]]; then
        env_args="${env_args} -e HF_TOKEN=${HF_TOKEN}"
    fi

    # Read onstart script
    local onstart_cmd
    onstart_cmd=$(build_onstart_cmd)

    log "Creating instance..."
    local result
    result=$(vastai create instance "$offer_id" \
        --template_hash "$TEMPLATE_HASH" \
        --disk "$DISK_SIZE" \
        --ssh \
        --direct \
        --env "${env_args}" \
        --onstart-cmd "$onstart_cmd" \
        --raw 2>/dev/null)

    local instance_id
    instance_id=$(echo "$result" | jq -r '.new_contract // empty')
    if [[ -z "$instance_id" ]]; then
        err "Failed to create instance. Response:"
        echo "$result" >&2
        die "Instance creation failed."
    fi

    log "Instance created: ${instance_id}"

    # Label the instance for identification
    vastai label instance "$instance_id" "$INSTANCE_LABEL" 2>/dev/null || true

    wait_for_ready "$instance_id"

    log ""
    log "================================================="
    log "  ComfyUI instance is live!"
    log "  Instance ID: ${instance_id}"
    log "  GPU: ${gpu_name} (${gpu_ram}GB)"
    log "  Cost: \$${dph}/hr"
    log ""
    log "  Access ComfyUI:"
    log "    ./deploy-worker.sh tunnel"
    log "    Open http://localhost:8188"
    log ""
    log "  Other commands:"
    log "    ./deploy-worker.sh ssh"
    log "    ./deploy-worker.sh logs"
    log "    ./deploy-worker.sh status"
    log "================================================="
}

cmd_down() {
    require_cmd vastai

    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with label '${INSTANCE_LABEL}'."

    log "Destroying instance ${instance_id} (this is irreversible)..."
    vastai destroy instance "$instance_id"
    log "Instance destruction initiated."
}

cmd_stop() {
    require_cmd vastai

    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with label '${INSTANCE_LABEL}'."

    log "Stopping instance ${instance_id} (data preserved, small storage fee)..."
    vastai stop instance "$instance_id"
    log "Instance stopping. Use './deploy-worker.sh start' to resume."
}

cmd_start() {
    require_cmd vastai

    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with label '${INSTANCE_LABEL}'."

    local status
    status=$(get_instance_status)
    if [[ "$status" == "running" ]]; then
        log "Instance is already running."
        cmd_status
        return 0
    fi

    log "Starting instance ${instance_id}..."
    vastai start instance "$instance_id"

    wait_for_ready "$instance_id"
    log "Instance is running. Use './deploy-worker.sh tunnel' to access ComfyUI."
}

cmd_status() {
    require_cmd vastai
    require_cmd jq

    local instance
    instance=$(find_instance)
    if [[ -z "$instance" ]]; then
        log "No instance found with label '${INSTANCE_LABEL}'."
        return 0
    fi

    local id status gpu_name gpu_ram dph ssh_url
    id=$(echo "$instance" | jq -r '.id')
    status=$(echo "$instance" | jq -r '.actual_status // .intended_status // "unknown"')
    gpu_name=$(echo "$instance" | jq -r '.gpu_name // "N/A"')
    gpu_ram=$(echo "$instance" | jq -r '.gpu_ram // "N/A"')
    dph=$(echo "$instance" | jq -r '.dph_total // "N/A"')

    printf "\n"
    printf "  \033[1mInstance:\033[0m  %s\n" "$id"
    printf "  \033[1mStatus:\033[0m    %s\n" "$status"
    printf "  \033[1mGPU:\033[0m       %s (%sGB VRAM)\n" "$gpu_name" "$gpu_ram"
    printf "  \033[1mCost:\033[0m      \$%s/hr\n" "$dph"

    if [[ "$status" == "running" ]]; then
        ssh_url=$(get_ssh_info "$id" 2>/dev/null || echo "")
        if [[ -n "$ssh_url" ]]; then
            printf "  \033[1mSSH:\033[0m       %s\n" "$ssh_url"
        fi
        printf "  \033[1mComfyUI:\033[0m   ./deploy-worker.sh tunnel  →  http://localhost:8188\n"
    fi
    printf "\n"
}

cmd_ssh() {
    require_cmd vastai

    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No running instance found."

    local ssh_url
    ssh_url=$(get_ssh_info "$instance_id")
    [[ -z "$ssh_url" ]] && die "Could not get SSH info for instance ${instance_id}."

    log "Connecting to instance ${instance_id}..."
    log "  ${ssh_url}"

    local host port
    host=$(parse_ssh_host "$ssh_url")
    port=$(parse_ssh_port "$ssh_url")

    if [[ -n "$host" && -n "$port" ]]; then
        ssh "${SSH_OPTS[@]}" -p "$port" "root@${host}"
    else
        # Fall back to running the ssh-url output directly
        eval "$ssh_url"
    fi
}

cmd_tunnel() {
    require_cmd vastai

    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No running instance found."

    local ssh_url
    ssh_url=$(get_ssh_info "$instance_id")
    [[ -z "$ssh_url" ]] && die "Could not get SSH info for instance ${instance_id}."

    local host port
    host=$(parse_ssh_host "$ssh_url")
    port=$(parse_ssh_port "$ssh_url")

    if [[ -z "$host" || -z "$port" ]]; then
        die "Could not parse SSH host/port from: ${ssh_url}"
    fi

    # Local port: optional override if 8188 is already in use (e.g. leftover tunnel)
    local local_port="${TUNNEL_LOCAL_PORT:-8188}"

    log "Opening SSH tunnel to ComfyUI..."
    log "  Remote: ${host}:${port} → localhost:${local_port}"
    log ""
    log "  ComfyUI will be available at: http://localhost:${local_port}"
    log "  Press Ctrl+C to close the tunnel."
    log "  If the page does not load, ComfyUI may still be starting on the instance."
    log "  Check progress: ./deploy-worker.sh logs"
    if [[ "$local_port" != "8188" ]]; then
        log "  (Using port ${local_port} because TUNNEL_LOCAL_PORT is set.)"
    else
        log "  (If port 8188 is in use: TUNNEL_LOCAL_PORT=8189 ./deploy-worker.sh tunnel)"
    fi
    log ""

    ssh "${SSH_OPTS[@]}" \
        -N \
        -p "$port" \
        -L "${local_port}:localhost:8188" \
        "root@${host}"
}

cmd_logs() {
    require_cmd vastai

    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with label '${INSTANCE_LABEL}'."

    vastai logs "$instance_id"
}

# ── Init config ──────────────────────────────────────────────────────────────

cmd_init() {
    mkdir -p "$CONF_DIR"
    if [[ -f "$CONF_FILE" ]]; then
        log "Config already exists at ${CONF_FILE}"
        return 0
    fi

    cat > "$CONF_FILE" << 'CONF'
# =============================================================================
# infra/worker.conf — GPU Worker Vast.ai Configuration
# =============================================================================

# Vast.ai ComfyUI template hash
# Default: official ComfyUI template from https://cloud.vast.ai/templates/
TEMPLATE_HASH=f3fbe8736dd0645619432c664c90d7c7

# Minimum GPU VRAM in GB (24GB+ recommended for LTX-2)
#   24GB — RTX 3090, RTX 4090, A10G, L4
#   48GB — RTX 6000, A6000, L40
#   80GB — A100, H100
GPU_MIN_RAM=24

# GPU model filter (optional, leave empty for any GPU meeting VRAM requirement)
# Replace spaces with underscores: RTX_4090, RTX_3090, A100_SXM4, etc.
GPU_NAME=

# Disk size in GB (200GB+ recommended for ComfyUI + LTX-2 models)
DISK_SIZE=200

# Maximum price per hour in USD (empty = no limit, cheapest available)
MAX_PRICE=

# Hugging Face token for gated models (e.g. Gemma-3 text encoder)
# Prefer setting HUGGING_FACE_API_KEY in .env; this overrides if set
# Get yours at: https://huggingface.co/settings/tokens
# HF_TOKEN=
CONF

    log "Config created at ${CONF_FILE}"
    log "Edit it to customize your deployment, then run: ./deploy-worker.sh up"
}

# ── Main ─────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ./deploy-worker.sh <command>

Commands:
  init      Create default config at infra/worker.conf
  up        Launch a GPU instance with ComfyUI + LTX-2 on Vast.ai
  down      Destroy the instance (irreversible, deletes data)
  stop      Stop the instance (preserves data, small storage fee)
  start     Start a previously stopped instance
  status    Show instance info (ID, GPU, status, cost)
  ssh       SSH into the instance
  tunnel    Open SSH tunnel — ComfyUI at http://localhost:8188
  logs      Show instance logs

Prerequisites:
  pip install vastai        # install Vast.ai CLI
  vastai set api-key KEY    # configure API key
  brew install jq           # install jq (macOS)

EOF
}

ACTION="${1:-help}"

case "$ACTION" in
    init)   cmd_init ;;
    up)     cmd_up ;;
    down)   cmd_down ;;
    stop)   cmd_stop ;;
    start)  cmd_start ;;
    status) cmd_status ;;
    ssh)    cmd_ssh ;;
    tunnel) cmd_tunnel ;;
    logs)   cmd_logs ;;
    *)      usage ;;
esac
