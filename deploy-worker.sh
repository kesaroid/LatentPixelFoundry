#!/usr/bin/env bash
# =============================================================================
# deploy-worker.sh — Provision and manage a GPU EC2 instance for the worker
# =============================================================================
#
# Usage:
#   ./deploy-worker.sh up        Launch instance, build Docker image, run worker
#   ./deploy-worker.sh down      Terminate the instance
#   ./deploy-worker.sh stop      Stop the instance (preserves EBS — no GPU cost)
#   ./deploy-worker.sh start     Start a previously stopped instance
#   ./deploy-worker.sh status    Show instance state and IP
#   ./deploy-worker.sh ssh       SSH into the instance
#   ./deploy-worker.sh build     Rebuild and restart the worker container
#   ./deploy-worker.sh logs      Tail worker container logs
#
# Prerequisites:
#   - AWS CLI v2 configured (aws configure)
#   - jq installed (brew install jq)
#
# Configuration is read from infra/worker.conf (created on first run).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/infra"
CONF_FILE="${CONF_DIR}/worker.conf"

# ── Defaults (overridden by worker.conf) ─────────────────────────────────────

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
VOLUME_SIZE="${VOLUME_SIZE:-150}"
KEY_NAME="${KEY_NAME:-lpf-worker-key}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/${KEY_NAME}.pem}"
SG_NAME="${SG_NAME:-lpf-worker-sg}"
INSTANCE_TAG="lpf-worker"
SSH_USER="ubuntu"
USE_SPOT="${USE_SPOT:-false}"
SPOT_MAX_PRICE="${SPOT_MAX_PRICE:-0.50}"

MODELS_S3_URI="${MODELS_S3_URI:-}"

# ── Load config if it exists ─────────────────────────────────────────────────

if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { printf "\033[36m[lpf]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[lpf]\033[0m %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required but not installed."
}

# ── Find instance by tag ─────────────────────────────────────────────────────

find_instance() {
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=${INSTANCE_TAG}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0]' \
        --output json 2>/dev/null | jq -r 'select(. != null)'
}

get_instance_id() {
    find_instance | jq -r '.InstanceId // empty'
}

get_public_ip() {
    find_instance | jq -r '.PublicIpAddress // empty'
}

get_instance_state() {
    find_instance | jq -r '.State.Name // empty'
}

wait_for_state() {
    local target="$1" timeout_secs="${2:-300}" elapsed=0
    log "Waiting for instance to reach state: ${target}..."
    while true; do
        local state
        state=$(get_instance_state)
        if [[ "$state" == "$target" ]]; then
            log "Instance is ${target}."
            return 0
        fi
        if (( elapsed >= timeout_secs )); then
            die "Timed out waiting for state ${target} (stuck at ${state})."
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

wait_for_ssh() {
    local ip="$1" timeout_secs="${2:-300}" elapsed=0
    log "Waiting for SSH on ${ip}..."
    while true; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
               -i "$KEY_PATH" "${SSH_USER}@${ip}" "echo ok" &>/dev/null; then
            log "SSH is ready."
            return 0
        fi
        if (( elapsed >= timeout_secs )); then
            die "Timed out waiting for SSH."
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

remote_exec() {
    local ip="$1"; shift
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "${SSH_USER}@${ip}" "$@"
}

remote_copy() {
    local ip="$1"; shift
    rsync -az --progress -e "ssh -o StrictHostKeyChecking=no -i ${KEY_PATH}" "$@" "${SSH_USER}@${ip}:~/project/"
}

# ── Ensure SSH key pair exists ───────────────────────────────────────────────

ensure_key_pair() {
    if [[ -f "$KEY_PATH" ]]; then
        return 0
    fi
    log "Creating EC2 key pair '${KEY_NAME}'..."
    aws ec2 create-key-pair \
        --region "$AWS_REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "$KEY_PATH"
    chmod 400 "$KEY_PATH"
    log "Key saved to ${KEY_PATH}"
}

# ── Ensure security group exists ─────────────────────────────────────────────

ensure_security_group() {
    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${SG_NAME}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)

    if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
        echo "$sg_id"
        return 0
    fi

    log "Creating security group '${SG_NAME}'..."
    sg_id=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "LatentPixelFoundry GPU Worker" \
        --query 'GroupId' --output text)

    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" --group-id "$sg_id" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" --group-id "$sg_id" \
        --protocol tcp --port 9000 --cidr 0.0.0.0/0

    log "Security group created: ${sg_id}"
    echo "$sg_id"
}

# ── Find the best GPU AMI ───────────────────────────────────────────────────

find_gpu_ami() {
    local ami_id
    ami_id=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners amazon \
        --filters \
            "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text 2>/dev/null)

    if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
        die "Could not find a suitable NVIDIA GPU AMI in ${AWS_REGION}. Check your region or set a custom AMI in infra/worker.conf."
    fi
    echo "$ami_id"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_up() {
    local existing_id
    existing_id=$(get_instance_id)
    if [[ -n "$existing_id" ]]; then
        local state
        state=$(get_instance_state)
        if [[ "$state" == "running" ]]; then
            log "Instance ${existing_id} is already running."
            cmd_status
            return 0
        elif [[ "$state" == "stopped" ]]; then
            log "Instance ${existing_id} is stopped. Starting it..."
            cmd_start
            return 0
        fi
    fi

    require_cmd aws
    require_cmd jq
    require_cmd rsync

    ensure_key_pair
    local sg_id ami_id instance_id
    sg_id=$(ensure_security_group)
    ami_id=$(find_gpu_ami)
    log "Using AMI: ${ami_id}"
    log "Instance type: ${INSTANCE_TYPE}"

    local run_args=(
        --region "$AWS_REGION"
        --image-id "$ami_id"
        --instance-type "$INSTANCE_TYPE"
        --key-name "$KEY_NAME"
        --security-group-ids "$sg_id"
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_TAG}}]"
        --query 'Instances[0].InstanceId'
        --output text
    )

    if [[ "$USE_SPOT" == "true" ]]; then
        log "Requesting spot instance (max price: \$${SPOT_MAX_PRICE}/hr)..."
        run_args+=(--instance-market-options "{\"MarketType\":\"spot\",\"SpotOptions\":{\"SpotInstanceType\":\"one-time\",\"MaxPrice\":\"${SPOT_MAX_PRICE}\"}}")
    fi

    log "Launching EC2 instance..."
    instance_id=$(aws ec2 run-instances "${run_args[@]}")
    log "Instance ID: ${instance_id}"

    wait_for_state "running"

    local ip
    ip=$(get_public_ip)
    log "Public IP: ${ip}"

    wait_for_ssh "$ip"

    log "Syncing project files..."
    remote_exec "$ip" "mkdir -p ~/project"
    remote_copy "$ip" "${SCRIPT_DIR}/worker/"
    remote_copy "$ip" "${SCRIPT_DIR}/.env" 2>/dev/null || true

    if [[ -n "$MODELS_S3_URI" ]]; then
        log "Downloading model files from ${MODELS_S3_URI}..."
        remote_exec "$ip" "mkdir -p ~/models && aws s3 sync ${MODELS_S3_URI} ~/models"
    fi

    log "Building Docker image on instance..."
    remote_exec "$ip" "cd ~/project && docker build --platform linux/amd64 -t lpf-worker -f worker/Dockerfile ."

    _start_container "$ip"

    log ""
    log "================================================="
    log "  Worker is live!"
    log "  URL:  http://${ip}:9000"
    log "  SSH:  ./deploy-worker.sh ssh"
    log "  Logs: ./deploy-worker.sh logs"
    log "================================================="
    log ""
    log "Update your local .env:"
    log "  MOCK_WORKER=false"
    log "  WORKER_URL=http://${ip}:9000/generate"
}

cmd_build() {
    local ip
    ip=$(get_public_ip)
    [[ -z "$ip" ]] && die "No running instance found."

    log "Syncing project files..."
    remote_exec "$ip" "mkdir -p ~/project"
    remote_copy "$ip" "${SCRIPT_DIR}/worker/"

    log "Rebuilding Docker image..."
    remote_exec "$ip" "cd ~/project && docker build --platform linux/amd64 -t lpf-worker -f worker/Dockerfile ."

    log "Restarting container..."
    remote_exec "$ip" "docker rm -f lpf-worker 2>/dev/null || true"
    _start_container "$ip"

    log "Worker rebuilt and restarted at http://${ip}:9000"
}

_start_container() {
    local ip="$1"
    local models_mount="${MODELS_PATH:-$HOME/models}"

    local env_flags=""
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        env_flags="--env-file ~/project/.env"
    fi

    remote_exec "$ip" "docker run -d \
        --name lpf-worker \
        --gpus all \
        --restart unless-stopped \
        -p 9000:9000 \
        -v ~/models:/models \
        ${env_flags} \
        -e BACKEND_URL=\${BACKEND_URL:-http://host.docker.internal:8000} \
        lpf-worker"
}

cmd_down() {
    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with tag '${INSTANCE_TAG}'."

    log "Terminating instance ${instance_id}..."
    aws ec2 terminate-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" > /dev/null
    log "Instance termination initiated. It will be fully terminated in ~60s."
}

cmd_stop() {
    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with tag '${INSTANCE_TAG}'."

    log "Stopping instance ${instance_id} (EBS preserved, no GPU charges)..."
    aws ec2 stop-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" > /dev/null
    log "Instance stopping. Use './deploy-worker.sh start' to resume."
}

cmd_start() {
    local instance_id
    instance_id=$(get_instance_id)
    [[ -z "$instance_id" ]] && die "No instance found with tag '${INSTANCE_TAG}'."

    local state
    state=$(get_instance_state)
    if [[ "$state" == "running" ]]; then
        log "Instance is already running."
        cmd_status
        return 0
    fi

    log "Starting instance ${instance_id}..."
    aws ec2 start-instances \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" > /dev/null

    wait_for_state "running"
    local ip
    ip=$(get_public_ip)
    wait_for_ssh "$ip"

    log "Instance running at ${ip}"
    log "Worker URL: http://${ip}:9000"
}

cmd_status() {
    local instance
    instance=$(find_instance)
    if [[ -z "$instance" ]]; then
        log "No instance found with tag '${INSTANCE_TAG}'."
        return 0
    fi

    local id state ip type launch_time
    id=$(echo "$instance" | jq -r '.InstanceId')
    state=$(echo "$instance" | jq -r '.State.Name')
    ip=$(echo "$instance" | jq -r '.PublicIpAddress // "N/A"')
    type=$(echo "$instance" | jq -r '.InstanceType')
    launch_time=$(echo "$instance" | jq -r '.LaunchTime')

    printf "\n"
    printf "  \033[1mInstance:\033[0m  %s\n" "$id"
    printf "  \033[1mState:\033[0m     %s\n" "$state"
    printf "  \033[1mType:\033[0m      %s\n" "$type"
    printf "  \033[1mIP:\033[0m        %s\n" "$ip"
    printf "  \033[1mLaunched:\033[0m  %s\n" "$launch_time"
    if [[ "$state" == "running" && "$ip" != "N/A" ]]; then
        printf "  \033[1mWorker:\033[0m    http://%s:9000\n" "$ip"
    fi
    printf "\n"
}

cmd_ssh() {
    local ip
    ip=$(get_public_ip)
    [[ -z "$ip" ]] && die "No running instance found."
    log "Connecting to ${ip}..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "${SSH_USER}@${ip}"
}

cmd_logs() {
    local ip
    ip=$(get_public_ip)
    [[ -z "$ip" ]] && die "No running instance found."
    remote_exec "$ip" "docker logs -f lpf-worker"
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
# infra/worker.conf — GPU Worker EC2 Configuration
# =============================================================================

# AWS region for the GPU instance
AWS_REGION=us-east-1

# EC2 instance type (GPU required)
#   g5.xlarge  — 1x A10G 24GB VRAM, ~$1.01/hr on-demand
#   g4dn.xlarge — 1x T4 16GB VRAM, ~$0.53/hr on-demand
#   g6.xlarge  — 1x L4 24GB VRAM, ~$0.98/hr on-demand
INSTANCE_TYPE=g5.xlarge

# Root EBS volume size in GB (needs space for Docker images + model cache)
VOLUME_SIZE=150

# SSH key pair name and local path
KEY_NAME=lpf-worker-key
KEY_PATH=$HOME/.ssh/lpf-worker-key.pem

# Security group name
SG_NAME=lpf-worker-sg

# Use spot instances for ~60-70% savings (may be interrupted)
USE_SPOT=false
SPOT_MAX_PRICE=0.50

# S3 URI for pre-cached model files (optional, speeds up cold start)
# If empty, you must manually download models to ~/models on the instance.
# Example: s3://my-bucket/lpf-models
MODELS_S3_URI=
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
  up        Launch a GPU instance, build Docker image, start worker
  down      Terminate the instance (destroys everything)
  stop      Stop the instance (preserves disk, no GPU charges)
  start     Start a previously stopped instance
  build     Rebuild Docker image and restart worker on running instance
  status    Show instance info (ID, state, IP)
  ssh       SSH into the instance
  logs      Tail worker container logs

EOF
}

ACTION="${1:-help}"

case "$ACTION" in
    init)   cmd_init ;;
    up)     cmd_up ;;
    down)   cmd_down ;;
    stop)   cmd_stop ;;
    start)  cmd_start ;;
    build)  cmd_build ;;
    status) cmd_status ;;
    ssh)    cmd_ssh ;;
    logs)   cmd_logs ;;
    *)      usage ;;
esac
