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

Downloads the full `Lightricks/LTX-2` repo to `~/models/ltx2` in diffusers format (~60GB with fp8 checkpoint). Excludes full-precision checkpoints (saves ~70GB). Set `CHECKPOINT_FILENAME=ltx-2-19b-dev-fp8.safetensors` for g5.xlarge/g5.2xlarge.

### Option B: Manual download

Replicate the script with `huggingface_hub`:

```bash
pip install huggingface_hub
python -c "from huggingface_hub import snapshot_download; snapshot_download('Lightricks/LTX-2', local_dir='$HOME/models/ltx2', local_dir_use_symlinks=False)"
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

### Is LTX-2 running inside the container?

**Out of the box: no.** The container runs a small FastAPI app that serves **GET /health** and **POST /generate** (accepts job, returns 202). It does **not** load the LTX-2 model or run inference yet—`/generate` is a stub. So the container is running, but LTX-2 is not “spun up” until you add inference code.

### How to run and use the worker

1. **Container is already running** after `./deploy-worker.sh up` or `./deploy-worker.sh build` (port 9000 on the instance).

2. **Check it’s up** (from your Mac; use IP from `./deploy-worker.sh status`):
   ```bash
   curl http://<INSTANCE_IP>:9000/health
   # → {"status":"ok"}
   ```

3. **Trigger from the app**: In local `.env` set `MOCK_WORKER=false`, `WORKER_URL=http://<INSTANCE_IP>:9000/generate`, and `WORKER_API_KEY` to match the worker. Create a job from the frontend; the backend will POST to the worker. The worker will accept (202) but will not generate video until LTX-2 is wired in.

4. **Trigger manually** (for testing):
   ```bash
   curl -X POST http://<INSTANCE_IP>:9000/generate \
     -H "Content-Type: application/json" \
     -d '{"job_id":"test-1","prompt":"A cat","duration":5,"resolution":"720p","backend_url":"http://backend:8000","upload_url":"http://backend:8000/api/jobs/test-1/upload","status_url":"http://backend:8000/api/jobs/test-1/status"}'
   # → 202 with {"status":"accepted","job_id":"test-1"}
   ```

### How to run real LTX-2 inference

The worker implements the full two-stage LTX-2 pipeline in `worker/pipeline_ltx2.py` and `worker/main.py`: on POST `/generate` it runs the pipeline, PATCHes `status_url`, and uploads the MP4 to `upload_url`. **Test the pipeline with a single prompt** (run **inside the worker container**; the host Python does not have torch/diffusers):

```bash
# From your Mac: SSH to instance then run inside the container
./deploy-worker.sh ssh
# On the instance:
docker exec -it lpf-worker python3 /app/scripts/run_prompt.py --prompt "A cat walking in the rain" --duration 5 --output /tmp/test.mp4
# Output is in the container at /tmp/test.mp4; copy out with:
docker cp lpf-worker:/tmp/test.mp4 /tmp/test.mp4
# Options: --resolution 720p|480p|1080p, --seed 42
```

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

## 5. Troubleshooting: Connection refused on port 9000

If `curl http://<INSTANCE_IP>:9000/health` returns **Connection refused**:

**1. Check the container on the instance**

```bash
./deploy-worker.sh ssh
# On the instance:
docker ps -a
docker logs lpf-worker
```

- If `lpf-worker` is **Exited**: see `docker logs lpf-worker` for the error (e.g. missing env, port in use). Fix and run `docker start lpf-worker`, or from your Mac run `./deploy-worker.sh build` to sync, rebuild, and restart.
- If the container is **Running** but you still get connection refused from your Mac, the firewall is likely blocking port 9000.

**2. Open port 9000 in the instance security group**

If the security group was created before port 9000 was added, allow it (from your Mac, replace `lpf-worker-sg` and `us-east-1` if you use different names/region):

```bash
aws ec2 authorize-security-group-ingress \
  --region us-east-1 \
  --group-name lpf-worker-sg \
  --protocol tcp --port 9000 --cidr 0.0.0.0/0
```

If you get "Duplicate" error, the rule already exists (check instance subnet / NACLs). Then retry:

```bash
curl http://<INSTANCE_IP>:9000/health
```

---

## 6. Quick Reference

### Health check

```bash
curl http://<INSTANCE_IP>:9000/health
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
