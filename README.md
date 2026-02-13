# AI Video Generator

A production-ready V1 system for AI video generation. Submit a text prompt, generate video using a cloud GPU worker, and download the result.

---

## Architecture Overview (V1)

```
┌─────────────┐     ┌──────────────┐     ┌───────────┐     ┌──────────────┐
│   Frontend   │────▶│  Backend API │────▶│  Worker    │     │  PostgreSQL  │
│  (Next.js)   │◀────│  (FastAPI)   │◀────│  (Cloud)   │     │  (Docker)    │
└─────────────┘     └──────┬───────┘     └───────────┘     └──────────────┘
                           │                                       ▲
                           │          ┌──────────────┐             │
                           └─────────▶│  Local Disk   │             │
                                      │  /generated_  │◀────────────┘
                                      │   videos/     │   (job records)
                                      └──────────────┘
```

**Flow:**
1. User submits a text prompt from the dashboard
2. Backend creates a job record in Postgres (status: PENDING)
3. Backend triggers the cloud GPU worker (or mock worker locally)
4. Worker generates video, uploads it back to the backend
5. Backend stores the video on local disk, updates job status to COMPLETED
6. Dashboard polls the backend and shows the downloadable video
7. User manually uploads to Instagram

---

## Technology Stack

| Component | Technology | Notes |
|-----------|-----------|-------|
| Backend API | FastAPI (async) | Python 3.11, ARM-compatible Docker |
| Database | PostgreSQL 16 | Alpine image, ARM-compatible |
| ORM | SQLModel + SQLAlchemy | Async via asyncpg |
| Worker (cloud) | Docker + CUDA | x86/amd64 only, not run locally |
| Worker (local) | Mock worker | Simulates GPU with delay + dummy MP4 |
| Frontend | Next.js | Separate branch/agent |

---

## Backend API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/api/jobs` | None | Create a new video generation job |
| `GET` | `/api/jobs` | None | List all jobs (newest first) |
| `GET` | `/api/jobs/{job_id}` | None | Get a single job by ID |
| `GET` | `/api/jobs/{job_id}/download` | None | Download the generated video |
| `POST` | `/api/jobs/{job_id}/upload` | `X-Worker-API-Key` | Worker uploads generated video |
| `PATCH` | `/api/jobs/{job_id}/status` | `X-Worker-API-Key` | Worker updates job status |
| `GET` | `/health` | None | Liveness probe |

See [CONTRACTS.md](CONTRACTS.md) for full request/response schemas.

---

## Job Status State Machine

```
PENDING ──▶ TRIGGERED ──▶ GENERATING ──▶ UPLOADING ──▶ COMPLETED
                                                   └──▶ FAILED
Any state can transition to FAILED on error.
```

| Status | Set By | Meaning |
|--------|--------|---------|
| PENDING | Backend | Job created, not yet triggered |
| TRIGGERED | Backend | Worker has been notified |
| GENERATING | Worker | Video generation in progress |
| UPLOADING | Worker | Generation done, uploading video |
| COMPLETED | Backend | Video received and stored |
| FAILED | Either | Something went wrong |

---

## Project Structure

```
/
├── backend/
│   ├── app/
│   │   ├── api/
│   │   │   ├── __init__.py     # Router exports
│   │   │   ├── deps.py         # Shared dependencies (auth, DB session)
│   │   │   └── jobs.py         # All job endpoints
│   │   ├── core/
│   │   │   ├── config.py       # Pydantic Settings (env vars)
│   │   │   ├── database.py     # Async engine + session factory
│   │   │   └── logging.py      # Structured logging
│   │   ├── models/
│   │   │   └── job.py          # Job table + Pydantic schemas
│   │   ├── services/
│   │   │   ├── job_service.py    # Job CRUD operations
│   │   │   ├── worker_service.py # Worker trigger (real + mock dispatch)
│   │   │   └── mock_worker.py    # Local mock worker simulation
│   │   └── main.py             # FastAPI app entry point
│   ├── generated_videos/       # Video output directory
│   ├── requirements.txt
│   └── Dockerfile
├── worker/                     # Cloud GPU worker (separate branch)
├── frontend/                   # Next.js dashboard (separate branch)
├── docker-compose.yml          # Local dev: postgres + backend
├── Makefile                    # Dev convenience commands
├── .env.example
├── .gitignore
└── CONTRACTS.md                # API contracts between all components
```

---

## Local Development

### Prerequisites

- Docker Desktop for Mac (ARM-native)
- Make (comes with Xcode CLI tools)

### Quick Start

```bash
# 1. Copy environment file
cp .env.example .env

# 2. Start postgres + backend
make up

# 3. Backend is now at http://localhost:8000
#    API docs at http://localhost:8000/docs
#    Health check at http://localhost:8000/health
```

### Available Make Commands

| Command | Description |
|---------|-------------|
| `make up` | Start all services (foreground) |
| `make up-d` | Start all services (background) |
| `make down` | Stop all services |
| `make down-v` | Stop services + delete DB data |
| `make logs` | Tail backend logs |
| `make shell` | Open shell in backend container |
| `make db-reset` | Drop and recreate database |
| `make clean` | Remove generated video files |
| `make status` | Show running containers |

### Mock Worker Mode

When `MOCK_WORKER=true` (the default), the backend simulates the GPU worker:

1. Job is created with status PENDING
2. Backend triggers the mock worker in an asyncio background task
3. Mock worker transitions through TRIGGERED -> GENERATING (with configurable delay) -> UPLOADING -> COMPLETED
4. A minimal valid MP4 file is written to `generated_videos/`
5. The dashboard can poll and download the result

This lets you fully test the entire pipeline on an M1 Mac without any GPU.

Set `MOCK_DELAY_SECONDS` in `.env` to control the simulated generation time (default: 5 seconds).

### Testing the API

```bash
# Create a job
curl -X POST http://localhost:8000/api/jobs \
  -H "Content-Type: application/json" \
  -d '{"prompt": "A cat walking in the rain", "duration": 5, "resolution": "720p"}'

# List all jobs
curl http://localhost:8000/api/jobs

# Get a specific job
curl http://localhost:8000/api/jobs/{job_id}

# Download video (after COMPLETED)
curl -o video.mp4 http://localhost:8000/api/jobs/{job_id}/download
```

---

## Docker Strategy — Multi-Architecture

| Image | Architecture | Base | Used Where |
|-------|-------------|------|-----------|
| Backend | `linux/arm64` | `python:3.11-slim` | Local dev (M1), production |
| PostgreSQL | `linux/arm64` | `postgres:16-alpine` | Local dev (M1) |
| Worker | `linux/amd64` | NVIDIA CUDA base | Cloud GPU only |

**Key points:**
- `python:3.11-slim` and `postgres:16-alpine` are multi-arch images that natively support ARM64 — no emulation needed on M1.
- The worker Dockerfile uses an NVIDIA CUDA base image which is x86-only (`linux/amd64`). It is **never built or run locally**.
- Docker Desktop for Mac handles ARM images natively. There is zero Rosetta/QEMU overhead for the backend and database.

---

## Security

- Worker-to-backend communication is authenticated via the `X-Worker-API-Key` header
- The API key is configured via the `WORKER_API_KEY` environment variable
- Frontend-to-backend requires no authentication in V1
- All secrets are loaded from environment variables (never hardcoded)
- The `.env` file is gitignored

---

## Error Handling

- If the worker trigger fails, the job is marked FAILED with an error message
- If the upload fails mid-stream, partial files are cleaned up and the job is marked FAILED
- If the mock worker encounters any exception, it catches it and marks the job FAILED
- All error states are surfaced in the job record's `error_message` field
- Retry mechanism is a V2 enhancement (placeholder noted, not implemented)

---

## Production Deployment Notes

For production, beyond the scope of V1:

1. **Use a reverse proxy** (nginx, Traefik, or Caddy) in front of the backend
2. **Set a strong `WORKER_API_KEY`** — generate with `openssl rand -hex 32`
3. **Set `MOCK_WORKER=false`** and configure `WORKER_URL` to point to the cloud GPU endpoint
4. **Set `BACKEND_URL`** to the public URL the worker can reach (e.g., `https://api.yourdomain.com`)
5. **Use managed PostgreSQL** (e.g., RDS, Cloud SQL) instead of Docker Postgres
6. **Add Alembic** for database migrations
7. **Run uvicorn with multiple workers** behind gunicorn: `gunicorn backend.app.main:app -k uvicorn.workers.UvicornWorker -w 4`
8. **Set `LOG_LEVEL=WARNING`** in production

---

## V2 Roadmap

See [V2.md](V2.md) for the full V2 architecture plan.

### V2 Enhancements (Not Implemented)

1. **Object Storage** — Replace local disk with S3-compatible storage (MinIO, AWS S3). Worker uploads directly to object storage. Backend stores public URLs instead of local paths.
2. **Redis Job Queue** — Replace HTTP trigger with a Redis-backed queue (Celery, ARQ, or RQ). Enables retry, priority, and rate limiting.
3. **Instagram Automation** — Automatic posting to Instagram via the Graph API after video completion.
4. **User Authentication** — JWT-based auth with user accounts. Each user owns their jobs.
5. **Concurrency Control** — Limit concurrent GPU jobs per user/globally. Queue overflow protection.
6. **Autoscaling Workers** — Scale GPU workers based on queue depth (Kubernetes HPA, or serverless GPU like RunPod/Modal).
7. **Job Retry Mechanism** — Automatic retry with exponential backoff on transient failures. Configurable max retries.
8. **Analytics Dashboard** — Track generation times, success rates, popular prompts, cost per video.
9. **Webhook Notifications** — Notify users when their video is ready (email, Slack, webhook URL).
10. **Multi-model Support** — Support multiple video generation models. Let users choose.

### V2 Architecture

```
Dashboard ──▶ Backend API ──▶ Redis Queue ──▶ GPU Workers ──▶ Object Store
    ▲              │                              │                │
    │              ▼                              │                ▼
    │         PostgreSQL                          │          Instagram API
    │              │                              │
    └──────────────┴──────────── Status Updates ──┘
```

This architecture decouples job submission from execution, enables horizontal scaling, and removes the local disk bottleneck.
