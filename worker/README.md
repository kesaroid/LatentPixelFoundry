# Worker -- Cloud GPU Video Generator

The worker runs on a cloud GPU instance (x86 + CUDA). It receives generation requests from the backend, generates a video using CogVideoX-2b, and uploads the result back to the backend via a secure streaming upload.

**The worker never runs locally on M1.** Local development uses `MOCK_WORKER=true` on the backend instead.

**Status: V1 implementation complete.** FastAPI server, model loader, backend client with retry, Dockerfile, and requirements are all in place.

---

## Tech Stack

- **FastAPI** -- Lightweight HTTP server (receives job triggers, serves health check)
- **PyTorch + Diffusers** -- CogVideoX-2b video generation pipeline
- **httpx** -- Async HTTP client for uploading back to backend (with retry)
- **Pydantic Settings** -- Environment-based configuration
- **Docker** -- `nvidia/cuda:12.1.1-runtime-ubuntu22.04` on linux/amd64

---

## Directory Structure

```
worker/
  __init__.py                -- Package marker
  worker.py                  -- FastAPI app: /health, /generate, process_job background task
  model_loader.py            -- CogVideoX-2b lazy singleton, generate_video() function
  backend_client.py          -- HTTP client: status updates + file upload with retry
  config.py                  -- WorkerSettings via pydantic-settings
  requirements.txt           -- torch, diffusers, accelerate, transformers, httpx, etc.
  Dockerfile                 -- CUDA 12.1, Python 3.11 (deadsnakes PPA), ffmpeg
```

---

## How It Works

1. Backend sends `POST /generate` with job payload
2. Worker responds `202 Accepted` immediately
3. Worker processes asynchronously in a background task (`process_job`):
   - Calls `PATCH /api/jobs/{id}/status` -> `GENERATING`
   - Runs `generate_video()` in a thread pool executor (non-blocking)
   - Calls `PATCH /api/jobs/{id}/status` -> `UPLOADING` (includes generation_time_seconds)
   - Streams video to `POST /api/jobs/{id}/upload` via multipart form
   - Backend marks job COMPLETED on successful upload
4. On any failure: calls status update with `FAILED` and error message (truncated to 4000 chars)
5. Temp file is always cleaned up in `finally` block

---

## Endpoints

| Method | Path        | Description                                      |
|--------|-------------|--------------------------------------------------|
| GET    | `/health`   | Readiness probe -- returns `{"status": "ok"}`    |
| POST   | `/generate` | Accepts job, returns 202, processes in background |

### POST /generate -- Request Body

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

### POST /generate -- Response (202)

```json
{
  "status": "accepted",
  "job_id": "550e8400-e29b-41d4-a716-446655440000"
}
```

---

## Model Loader (`model_loader.py`)

- **Model:** `THUDM/CogVideoX-2b` (configurable via `MODEL_ID` env var)
- **Loading strategy:** Lazy singleton -- loaded on first `generate_video()` call, cached for process lifetime
- **Device:** Auto-detects CUDA GPU (configurable via `DEVICE` env var)
- **Memory optimization:** Enables `model_cpu_offload()` when available
- **Resolution presets:**
  - 480p: 854x480
  - 720p: 1280x720
  - 1080p: 1920x1080
- **Frame rate:** 8 FPS (CogVideoX default)
- **Inference:** 50 steps, guidance scale 6.0
- **Output:** Exports frames to MP4 via `diffusers.utils.export_to_video`
- **Error handling:** Catches CUDA OOM specifically with descriptive messages

---

## Backend Client (`backend_client.py`)

Handles all communication back to the backend API.

### Features
- **Status updates:** `PATCH /api/jobs/{id}/status` with job metadata
- **File uploads:** `POST /api/jobs/{id}/upload` via streaming multipart form
- **Authentication:** All requests include `X-Worker-API-Key` header
- **Retry with exponential backoff:**
  - Default: 3 retries, 2-second base delay (2s, 4s, 8s)
  - Retries on: 502, 503, 504, 408, 429, connection errors, timeouts
  - Non-retryable errors (4xx) fail immediately
- **Upload timeout:** 300 seconds (configurable) to handle large video files

---

## Configuration (`config.py`)

| Variable          | Default                          | Description                             |
|-------------------|----------------------------------|-----------------------------------------|
| `WORKER_API_KEY`  | (change-me placeholder)          | Shared secret for backend auth          |
| `BACKEND_URL`     | `http://backend:8000`            | Backend base URL for callbacks          |
| `MODEL_ID`        | `THUDM/CogVideoX-2b`            | HuggingFace model identifier            |
| `DEVICE`          | `cuda`                           | PyTorch device                          |
| `TEMP_DIR`        | `/tmp/videogen`                  | Temp directory for generated files      |
| `WORKER_HOST`     | `0.0.0.0`                        | Server bind host                        |
| `WORKER_PORT`     | `9000`                           | Server bind port                        |
| `MAX_RETRIES`     | `3`                              | Retry count for backend calls           |
| `RETRY_DELAY`     | `2.0`                            | Base delay between retries (seconds)    |
| `UPLOAD_TIMEOUT`  | `300.0`                          | Upload HTTP timeout (seconds)           |
| `LOG_LEVEL`       | `INFO`                           | Logging verbosity                       |

---

## Docker

### Dockerfile

- **Base:** `nvidia/cuda:12.1.1-runtime-ubuntu22.04` (x86_64 ONLY)
- **Python:** 3.11 via deadsnakes PPA
- **System deps:** ffmpeg (for video export), curl (for healthcheck)
- **Health check:** `curl -f http://localhost:9000/health` every 30s, 60s start period
- **Non-blocking:** `PYTHONUNBUFFERED=1`

### Building

```bash
docker build --platform linux/amd64 -t videogen-worker -f worker/Dockerfile .
```

Build context is the **project root** (so `worker/` is available).

### Running on a GPU Instance

```bash
docker run --gpus all \
  -e WORKER_API_KEY=your-secret-key \
  -e BACKEND_URL=https://your-backend.example.com \
  -p 9000:9000 \
  videogen-worker
```

Requires NVIDIA Container Toolkit and GPU drivers on the host.

---

## File Lifecycle

1. Video is generated to a temp file: `/tmp/videogen/{job_id}.mp4`
2. Temp file is streamed to backend via multipart upload with retry
3. Temp file is **deleted in `finally` block** -- always cleaned up
4. On startup, leftover temp files from previous runs are cleaned up
5. Worker stores **no permanent files**

---

## Error Handling

| Failure                  | Behavior                                                    |
|--------------------------|-------------------------------------------------------------|
| CUDA OOM (model load)   | Raises RuntimeError with descriptive message                |
| CUDA OOM (generation)   | Raises RuntimeError suggesting shorter duration/lower res   |
| Model load failure       | Raises RuntimeError, logged at ERROR level                  |
| Backend connection error | Retries with exponential backoff (3 attempts)               |
| Backend 5xx              | Retries with exponential backoff                            |
| Backend 4xx              | Fails immediately (non-retryable)                           |
| Upload timeout           | Retries (300s timeout per attempt)                          |
| Any exception            | Job marked FAILED via status update, temp file cleaned up   |
| Status update failure    | Logged but does not re-raise (best effort)                  |

---

## Implementation Checklist

- [x] `worker.py` -- FastAPI app with /health and /generate, background task, temp cleanup on shutdown
- [x] `model_loader.py` -- CogVideoX-2b lazy singleton, generate_video(), resolution presets, OOM handling
- [x] `backend_client.py` -- Status updates, streaming upload, retry with exponential backoff
- [x] `config.py` -- WorkerSettings with all configurable knobs
- [x] `Dockerfile` -- CUDA 12.1, Python 3.11, ffmpeg, deadsnakes PPA, health check
- [x] `requirements.txt` -- torch, diffusers, accelerate, transformers, imageio, httpx, fastapi
- [x] `__init__.py` -- Package marker
- [ ] Unit tests (not yet -- V1 focuses on core functionality)
- [ ] GPU resource monitoring / metrics endpoint
