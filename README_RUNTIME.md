# Runtime Guide — GPU Worker

How to run the LTX-2 video generation worker, download models, and run end-to-end tests.

---

## Prerequisites

- **EC2 instance**: GPU instance (e.g. g5.xlarge) with NVIDIA drivers
- **Disk**: ~100GB free for models (FP8 checkpoint) or ~150GB (full checkpoint)
- **Docker**: With NVIDIA Container Toolkit (`--gpus all`)

---

## 1. EC2 Lifecycle (from your Mac)

```bash
# Launch instance, sync code, build image, start worker
./deploy-worker.sh up

# Stop instance (preserves disk, no GPU charges)
./deploy-worker.sh stop

# Resume stopped instance
./deploy-worker.sh start

# SSH into instance
./deploy-worker.sh ssh

# Rebuild and restart worker (after code changes)
./deploy-worker.sh build

# Terminate instance (destroys everything)
./deploy-worker.sh down
```

---

## 2. Download Models

Models are **not** included in the image. Download them on the instance before running the worker.

### Option A: All-in-one script (recommended)

On the instance:

```bash
# Copy scripts to instance (from your Mac)
scp -i ~/.ssh/lpf-worker-key.pem -r \
  /path/to/LatentPixelFoundry-worker/scripts \
  ubuntu@<INSTANCE_IP>:~/project/worker/

# On instance
chmod +x ~/project/worker/scripts/*.sh
~/project/worker/scripts/download_all_models.sh
```

Downloads (~60GB total):

- `ltx-2-19b-dev-fp8.safetensors` (~25GB) — FP8 checkpoint for g5.xlarge
- `ltx-2-19b-distilled-lora-384.safetensors` (~1.5GB)
- `ltx-2-spatial-upscaler-x2-1.0.safetensors` + symlink
- `gemma-3/` — text encoder from Lightricks/LTX-2

### Option B: Manual download

```bash
cd ~/models
BASE="https://huggingface.co/Lightricks/LTX-2/resolve/main"

# LTX-2 files
wget -O ltx-2-19b-dev-fp8.safetensors "$BASE/ltx-2-19b-dev-fp8.safetensors"
wget -O ltx-2-19b-distilled-lora-384.safetensors "$BASE/ltx-2-19b-distilled-lora-384.safetensors"
wget -O ltx-2-spatial-upscaler-x2-1.0.safetensors "$BASE/ltx-2-spatial-upscaler-x2-1.0.safetensors"
ln -s ltx-2-spatial-upscaler-x2-1.0.safetensors ltx-2-spatial-upsampler-x2-1.0.safetensors

# Gemma-3 text encoder
~/project/worker/scripts/download_gemma3.sh
```

### Option C: S3 (for deploy-worker.sh)

Set `MODELS_S3_URI` in `infra/worker.conf` to an S3 path with pre-cached models. `./deploy-worker.sh up` will sync from S3 instead of Hugging Face.

---

## 3. Run the Container

### On EC2 (for testing with mock backend)

```bash
docker rm -f lpf-worker 2>/dev/null

docker run -d \
  --name lpf-worker \
  --gpus all \
  --restart unless-stopped \
  -p 9000:9000 \
  -v ~/models:/models \
  -v /tmp/lpf-worker:/tmp \
  -e BACKEND_URL=http://172.17.0.1:8000 \
  -e WORKER_API_KEY=test-key \
  -e CHECKPOINT_FILENAME=ltx-2-19b-dev-fp8.safetensors \
  -e ENABLE_FP8=true \
  lpf-worker
```

**Important:**

- `-v ~/models:/models` — models must be at `~/models` on the host
- `-v /tmp/lpf-worker:/tmp` — writable temp dir (avoids "No usable temporary directory")
- `CHECKPOINT_FILENAME=ltx-2-19b-dev-fp8.safetensors` — use FP8 on g5.xlarge (16GB RAM)
- `BACKEND_URL=http://172.17.0.1:8000` — Docker bridge IP so the container can reach the host mock backend

### Production (real backend)

```bash
docker run -d \
  --name lpf-worker \
  --gpus all \
  --restart unless-stopped \
  -p 9000:9000 \
  -v ~/models:/models \
  -v /tmp/lpf-worker:/tmp \
  -e BACKEND_URL=https://your-backend.example.com \
  -e WORKER_API_KEY=your-secret-key \
  -e CHECKPOINT_FILENAME=ltx-2-19b-dev-fp8.safetensors \
  -e ENABLE_FP8=true \
  lpf-worker
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKEND_URL` | `http://backend:8000` | Backend base URL for callbacks |
| `WORKER_API_KEY` | — | Shared secret for `X-Worker-API-Key` |
| `CHECKPOINT_FILENAME` | `ltx-2-19b-dev.safetensors` | Checkpoint file in `/models` |
| `ENABLE_FP8` | `false` | Use FP8 inference (set `true` with FP8 checkpoint) |

---

## 4. End-to-End Test

The test script runs on the **host** (not in the container). It starts a mock backend, sends a generate request to the worker, and receives the video.

### Setup (once)

```bash
# Copy test script to instance (from your Mac)
scp -i ~/.ssh/lpf-worker-key.pem \
  /path/to/LatentPixelFoundry-worker/test_generate.py \
  ubuntu@<INSTANCE_IP>:~/project/worker/

# On instance: install deps
pip3 install httpx uvicorn fastapi python-multipart
```

### Run test

```bash
cd ~/project/worker
python3 test_generate.py --duration 2 --resolution 480p --prompt "A cat walking in the rain"
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--worker-url` | `http://localhost:9000` | Worker base URL |
| `--mock-port` | `8000` | Mock backend port |
| `--prompt` | (golden retriever meadow) | Generation prompt |
| `--duration` | `2` | Video duration (seconds) |
| `--resolution` | `480p` | 480p, 720p, or 1080p |
| `--timeout` | `600` | Max wait (seconds) |
| `--api-key` | `test-key` | Must match `WORKER_API_KEY` |

### Output

- **Success**: Video saved to `~/project/worker/test_outputs/<job_id>.mp4`
- **Download to Mac**: `scp -i ~/.ssh/lpf-worker-key.pem ubuntu@<IP>:~/project/worker/test_outputs/*.mp4 ./`

---

## 5. Quick Reference

### Health check

```bash
curl http://localhost:9000/health
```

### Container logs

```bash
docker logs -f lpf-worker
```

### Clean models and re-download

```bash
docker rm -f lpf-worker
rm -rf ~/models
mkdir -p ~/models
~/project/worker/scripts/download_all_models.sh
```

### Disk space

- FP8 setup: ~60GB
- Full checkpoint: ~100GB
- Recommended EBS: 200GB+ (`VOLUME_SIZE` in `infra/worker.conf`)
