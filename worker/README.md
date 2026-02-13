# Worker -- Cloud GPU Video Generator

The worker runs on a cloud GPU instance (x86 + CUDA). It receives generation requests from the backend, generates a video using an open-source AI model, and uploads the result back to the backend.

**The worker never runs locally on M1.** Local development uses `MOCK_WORKER=true` on the backend instead.

---

## Tech Stack

- **FastAPI** -- Lightweight HTTP server to receive job triggers
- **PyTorch + Diffusers** -- AI video generation
- **httpx** -- Async HTTP client for uploading back to backend
- **Docker** -- `nvidia/cuda:12.1-runtime-ubuntu22.04` on linux/amd64

---

## Directory Structure

```
worker/
  worker.py                  <-- FastAPI app, /generate endpoint, generation + upload logic
  model_loader.py            <-- Load and cache the video generation model
  requirements.txt
  Dockerfile
```

---

## How It Works

1. Backend sends `POST /generate` with job payload
2. Worker responds `202 Accepted` immediately
3. Worker processes asynchronously in a background task:
   a. Calls `PATCH /api/jobs/{id}/status` on backend with `GENERATING`
   b. Loads model (cached after first load)
   c. Generates video to a temp file
   d. Calls `PATCH /api/jobs/{id}/status` with `UPLOADING`
   e. Streams video to `POST /api/jobs/{id}/upload` with API key header
   f. On success: backend updates job to COMPLETED
   g. Deletes temp file
4. On any failure: calls status update with `FAILED` and error message

---

## Input Contract

`POST /generate` request body:

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "prompt": "A cat walking in the rain",
  "duration": 5,
  "resolution": "720p",
  "backend_url": "http://backend:8000",
  "upload_url": "http://backend:8000/api/jobs/550e.../upload",
  "status_url": "http://backend:8000/api/jobs/550e.../status"
}
```

Response: `202 Accepted` with `{ "status": "accepted", "job_id": "..." }`

---

## Backend Communication

All calls back to the backend include the `X-Worker-API-Key` header.

| Action         | Method | Backend Endpoint             |
|----------------|--------|------------------------------|
| Update status  | PATCH  | `/api/jobs/{id}/status`      |
| Upload video   | POST   | `/api/jobs/{id}/upload`      |

---

## Configuration

| Variable         | Required | Description                                    |
|------------------|----------|------------------------------------------------|
| `WORKER_API_KEY` | Yes      | Shared secret for authenticating to backend    |
| `BACKEND_URL`    | Yes      | Base URL of the backend (e.g. `http://backend:8000`) |
| `MODEL_PATH`     | No       | Local path to cached model weights             |
| `DEVICE`         | No       | PyTorch device (`cuda`, `cuda:0`, default: auto-detect) |

---

## Docker

### Base Image

```dockerfile
FROM nvidia/cuda:12.1-runtime-ubuntu22.04
```

This image is **x86 only (linux/amd64)** and requires NVIDIA GPU drivers on the host. It will NOT run on M1 Macs.

### Building

```bash
docker build --platform linux/amd64 -t latentpixel-worker:latest ./worker
```

### Running on a GPU Instance

```bash
docker run --gpus all \
  -e WORKER_API_KEY=your-secret-key \
  -e BACKEND_URL=https://your-backend.example.com \
  -p 9000:9000 \
  latentpixel-worker:latest
```

---

## Model Loading

`model_loader.py` handles:
- Loading the video generation model (e.g., ModelScope, AnimateDiff, or similar open-source model)
- Caching the model in memory after first load (singleton pattern)
- Device placement (auto-detect CUDA GPU)
- Model-specific configuration (steps, guidance scale, etc.)

The exact model choice is pluggable. V1 will use a single model. V2 adds multi-model support.

---

## File Lifecycle

1. Video is generated to a temp file: `/tmp/{job_id}.mp4`
2. Temp file is streamed to backend via multipart upload
3. Temp file is **deleted immediately** after successful upload
4. On failure, temp file is also cleaned up
5. Worker stores **no permanent files**

---

## Error Handling

- Generation timeout: configurable, job marked FAILED
- Upload failure: retry up to 3 times with exponential backoff, then FAILED
- Model loading failure: log error, return 503 to backend trigger
- All errors include descriptive messages sent back to backend via status update

---

## Implementation Checklist

- [ ] `worker.py` -- FastAPI app with `/generate` endpoint, background task, status callbacks, streaming upload
- [ ] `model_loader.py` -- Model singleton, device detection, generate function (stub for V1, real model integration later)
- [ ] `Dockerfile` -- CUDA base, Python deps, non-root user, health check
- [ ] `requirements.txt` -- torch, diffusers, accelerate, fastapi, httpx, uvicorn
- [ ] Temp file cleanup on success and failure
- [ ] Upload retry with exponential backoff
- [ ] Structured logging with job_id context
