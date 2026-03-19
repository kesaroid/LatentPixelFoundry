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
# Configuration: .env (secrets) then infra/worker.conf (deploy overrides).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/infra"
CONF_FILE="${CONF_DIR}/worker.conf"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Defaults (overridden by .env and worker.conf) ─────────────────────────────

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

INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-lpf-worker-profile}"
IAM_ROLE_NAME="${IAM_ROLE_NAME:-lpf-worker-role}"

MODELS_S3_URI="${MODELS_S3_URI:-}"
CHECKPOINT_FILENAME="${CHECKPOINT_FILENAME:-ltx-2-19b-dev-fp8.safetensors}"
HF_TOKEN="${HF_TOKEN:-}"
# Git repo to clone on EC2 (default: origin remote of current repo)
GIT_REPO_URL="${GIT_REPO_URL:-}"
# Default: use current branch so deploy includes worker scripts (e.g. download_all_models.sh)
GIT_BRANCH="${GIT_BRANCH:-}"

# ── Load config: .env first (secrets), then worker.conf (overrides) ───────────

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    # HF_TOKEN can come from .env as HUGGING_FACE_API_KEY
    HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_API_KEY:-}}"
fi
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONF_FILE"
    HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_API_KEY:-}}"
fi

# Resolve GIT_REPO_URL from git origin if not set
if [[ -z "${GIT_REPO_URL:-}" ]]; then
    GIT_REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)
fi
# Resolve GIT_BRANCH: default to current branch (so deploy uses worker scripts) or master
[[ -z "${GIT_BRANCH:-}" ]] && GIT_BRANCH=$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "master")

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
    local ip="$1" dest="$2"; shift 2
    rsync -az --progress -e "ssh -o StrictHostKeyChecking=no -i ${KEY_PATH}" "$@" "${SSH_USER}@${ip}:${dest}"
}

# ── Sync project via git clone + .env rsync ───────────────────────────────────

sync_project() {
    local ip="$1" mode="${2:-up}"
    [[ -z "$GIT_REPO_URL" ]] && die "GIT_REPO_URL is not set. Set it in infra/worker.conf or ensure this repo has a git origin."

    if [[ "$mode" == "up" ]]; then
        log "Cloning repo (branch: ${GIT_BRANCH})..."
        remote_exec "$ip" "rm -rf ~/project && git clone --branch '${GIT_BRANCH}' --single-branch '${GIT_REPO_URL}' ~/project"
    else
        log "Pulling latest..."
        remote_exec "$ip" "cd ~/project && git pull origin '${GIT_BRANCH}'"
    fi

    if [[ -f "$ENV_FILE" ]]; then
        log "Syncing .env..."
        remote_copy "$ip" "~/project/" "${ENV_FILE}"
    fi
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

    if [[ "$sg_id" == "None" || -z "$sg_id" ]]; then
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
    else
        # Ensure port 9000 is allowed (idempotent; duplicate rule is ignored)
        aws ec2 authorize-security-group-ingress \
            --region "$AWS_REGION" --group-id "$sg_id" \
            --protocol tcp --port 9000 --cidr 0.0.0.0/0 2>/dev/null || true
    fi
    echo "$sg_id"
}

# ── Ensure IAM instance profile with S3 access ──────────────────────────────

ensure_instance_profile() {
    local profile_arn
    profile_arn=$(aws iam get-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --query 'InstanceProfile.Arn' \
        --output text 2>/dev/null) || true

    if [[ -n "$profile_arn" && "$profile_arn" != "None" ]]; then
        return 0
    fi

    log "Creating IAM role '${IAM_ROLE_NAME}' with S3 access..."

    local trust_policy
    trust_policy=$(cat <<'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
TRUST
)

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "$trust_policy" \
        --output text > /dev/null 2>&1 || true

    local s3_policy
    s3_policy=$(cat <<'S3POL'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject","s3:PutObject","s3:ListBucket","s3:DeleteObject"],
    "Resource": ["arn:aws:s3:::lpf-models-*","arn:aws:s3:::lpf-models-*/*"]
  }]
}
S3POL
)

    aws iam put-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-name "lpf-s3-models-access" \
        --policy-document "$s3_policy"

    log "Creating instance profile '${INSTANCE_PROFILE_NAME}'..."
    aws iam create-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --output text > /dev/null 2>&1 || true

    aws iam add-role-to-instance-profile \
        --instance-profile-name "$INSTANCE_PROFILE_NAME" \
        --role-name "$IAM_ROLE_NAME" 2>/dev/null || true

    # Instance profiles need a few seconds to propagate
    log "Waiting for instance profile to propagate..."
    sleep 10

    log "IAM instance profile ready."
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

# ── Model downloads ──────────────────────────────────────────────────────────

HF_BASE_URL="https://huggingface.co"

LTX2_REPO="Lightricks/LTX-2"
# Default to FP8 checkpoint (~25GB) for g5.xlarge/g5.2xlarge (32GB RAM) to avoid mmap OOM
LTX2_FILES=(
    "$CHECKPOINT_FILENAME"
    "ltx-2-19b-distilled-lora-384.safetensors"
    "ltx-2-spatial-upscaler-x2-1.0.safetensors"
)

GEMMA_REPO="google/gemma-3-1b-it"

download_models() {
    local ip="$1"

    if [[ -n "$MODELS_S3_URI" ]]; then
        log "Syncing model files from S3: ${MODELS_S3_URI}..."
        local sync_start
        sync_start=$(date +%s)
        remote_exec "$ip" "sudo mkdir -p ~/models && sudo chown -R ubuntu:ubuntu ~/models && aws s3 sync '${MODELS_S3_URI}' ~/models --only-show-errors"
        local sync_elapsed=$(( $(date +%s) - sync_start ))
        log "S3 sync complete in ${sync_elapsed}s."
        return 0
    fi

    # Option A (README_RUNTIME): run scripts/download_all_models.sh on instance if present
    remote_exec "$ip" "sudo mkdir -p ~/models && sudo chown -R ubuntu:ubuntu ~/models"
    if remote_exec "$ip" "
        if [ -f ~/project/worker/scripts/download_all_models.sh ]; then
            chmod +x ~/project/worker/scripts/*.sh 2>/dev/null || true
            export CHECKPOINT_FILENAME='${CHECKPOINT_FILENAME}'
            export HF_TOKEN='${HF_TOKEN}'
            ~/project/worker/scripts/download_all_models.sh
        else
            exit 2
        fi
    "; then
        log "All model files ready (Option A)."
        return 0
    fi
    local ret=$?
    if [[ $ret -ne 2 ]]; then
        die "Model download failed (exit $ret). Fix errors above or set MODELS_S3_URI."
    fi

    log "Downloading model files from Hugging Face (inline fallback)..."
    local wget_auth=""
    if [[ -n "$HF_TOKEN" ]]; then
        wget_auth="--header='Authorization: Bearer ${HF_TOKEN}'"
    fi

    for f in "${LTX2_FILES[@]}"; do
        log "  Checking ${f}..."
        remote_exec "$ip" "
            if [ -f ~/models/${f} ]; then
                echo '  Already exists, skipping.'
            else
                echo '  Downloading ${f}...'
                wget ${wget_auth} -O ~/models/${f} '${HF_BASE_URL}/${LTX2_REPO}/resolve/main/${f}'
            fi
        "
    done

    remote_exec "$ip" "
        cd ~/models
        if [ -f ltx-2-spatial-upscaler-x2-1.0.safetensors ] && [ ! -f ltx-2-spatial-upsampler-x2-1.0.safetensors ]; then
            ln -s ltx-2-spatial-upscaler-x2-1.0.safetensors ltx-2-spatial-upsampler-x2-1.0.safetensors
            echo '  Created symlink: upscaler -> upsampler'
        fi
    "

    log "  Checking gemma-3 text encoder..."
    if [[ -z "$HF_TOKEN" ]]; then
        err "  HF_TOKEN is required to download Gemma-3 (gated model)."
        err "  Set HUGGING_FACE_API_KEY in .env or HF_TOKEN in infra/worker.conf"
        die "  Also accept the license at: ${HF_BASE_URL}/${GEMMA_REPO}"
    fi

    remote_exec "$ip" "
        if [ -d ~/models/gemma-3 ] && [ \"\$(ls -A ~/models/gemma-3 2>/dev/null)\" ]; then
            echo '  gemma-3/ already exists, skipping.'
        else
            echo '  Downloading Gemma-3 text encoder...'
            pip3 install -q huggingface_hub 2>/dev/null
            python3 -c \"
from huggingface_hub import snapshot_download
snapshot_download('${GEMMA_REPO}', local_dir='/home/ubuntu/models/gemma-3', token='${HF_TOKEN}')
print('  Gemma-3 download complete.')
\"
        fi
    "

    log "All model files ready."
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
    if [[ -n "$MODELS_S3_URI" ]]; then
        ensure_instance_profile
    fi
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

    if [[ -n "$MODELS_S3_URI" ]]; then
        run_args+=(--iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}")
    fi

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

    sync_project "$ip" up

    download_models "$ip"

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

    sync_project "$ip" build

    log "Ensuring models (Option A if script present)..."
    download_models "$ip"

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

    # Allow mmap of large model files (e.g. 43GB full checkpoint) when RAM+swap < file size.
    # See: https://github.com/huggingface/safetensors/issues/528
    remote_exec "$ip" "sudo sysctl -w vm.overcommit_memory=1 2>/dev/null || true"

    # Use --env-file only if .env exists on the instance (full path: Docker does not expand ~)
    remote_exec "$ip" '
        env_file="/home/ubuntu/project/.env"
        env_flags=""
        [ -f "$env_file" ] && env_flags="--env-file $env_file"
        docker run -d \
            --name lpf-worker \
            --gpus all \
            --restart unless-stopped \
            -p 9000:9000 \
            -v /home/ubuntu/models:/models \
            $env_flags \
            -e CHECKPOINT_FILENAME='"${CHECKPOINT_FILENAME}"' \
            -e BACKEND_URL=${BACKEND_URL:-http://host.docker.internal:8000} \
            lpf-worker
    '
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

# ── Cache models to S3 ───────────────────────────────────────────────────────

cmd_cache_models() {
    [[ -z "$MODELS_S3_URI" ]] && die "MODELS_S3_URI is not set. Set it in infra/worker.conf (e.g. s3://lpf-models-cache/models)."

    local ip
    ip=$(get_public_ip)
    [[ -z "$ip" ]] && die "No running instance found. Deploy first with './deploy-worker.sh up'."

    local bucket
    bucket=$(echo "$MODELS_S3_URI" | sed 's|s3://||' | cut -d/ -f1)

    log "Ensuring S3 bucket '${bucket}' exists..."
    aws s3 mb "s3://${bucket}" --region "$AWS_REGION" 2>/dev/null || true

    ensure_instance_profile

    log "Uploading ~/models to ${MODELS_S3_URI}..."
    local start_time
    start_time=$(date +%s)

    remote_exec "$ip" "aws s3 sync ~/models '${MODELS_S3_URI}' --only-show-errors"

    local elapsed=$(( $(date +%s) - start_time ))
    log "Upload complete in ${elapsed}s."

    local size
    size=$(remote_exec "$ip" "du -sh ~/models 2>/dev/null | cut -f1")
    log "Cached ${size} to ${MODELS_S3_URI}"
    log "Future deploys with MODELS_S3_URI set will sync from S3 instead of Hugging Face."
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
VOLUME_SIZE=300

# SSH key pair name and local path
KEY_NAME=lpf-worker-key
KEY_PATH=$HOME/.ssh/lpf-worker-key.pem

# Security group name
SG_NAME=lpf-worker-sg

# Use spot instances for ~60-70% savings (may be interrupted)
USE_SPOT=false
SPOT_MAX_PRICE=0.50

# S3 URI for pre-cached model files (speeds up cold start).
# Models are synced from S3 instead of Hugging Face when set.
# Upload once with: ./deploy-worker.sh cache-models
MODELS_S3_URI=s3://lpf-models-cache/models

# Hugging Face token for downloading models (required for Gemma-3)
# Prefer setting HUGGING_FACE_API_KEY in .env; this overrides if set
# Get yours at: https://huggingface.co/settings/tokens
# Also accept the Gemma-3 license at: https://huggingface.co/google/gemma-3-1b-it
# HF_TOKEN=

# Git repo to clone on EC2 (default: origin of the repo running this script)
# GIT_REPO_URL=
# GIT_BRANCH=main
CONF

    log "Config created at ${CONF_FILE}"
    log "Edit it to customize your deployment, then run: ./deploy-worker.sh up"
}

# ── Main ─────────────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ./deploy-worker.sh <command>

Commands:
  init          Create default config at infra/worker.conf
  up            Launch a GPU instance, build Docker image, start worker
  down          Terminate the instance (destroys everything)
  stop          Stop the instance (preserves disk, no GPU charges)
  start         Start a previously stopped instance
  build         Rebuild Docker image and restart worker on running instance
  cache-models  Upload ~/models from running instance to S3 (one-time)
  status        Show instance info (ID, state, IP)
  ssh           SSH into the instance
  logs          Tail worker container logs

EOF
}

ACTION="${1:-help}"

case "$ACTION" in
    init)          cmd_init ;;
    up)            cmd_up ;;
    down)          cmd_down ;;
    stop)          cmd_stop ;;
    start)         cmd_start ;;
    build)         cmd_build ;;
    cache-models)  cmd_cache_models ;;
    status)        cmd_status ;;
    ssh)           cmd_ssh ;;
    logs)          cmd_logs ;;
    *)             usage ;;
esac
