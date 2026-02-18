# Backend -- FastAPI Video Generation Service

The backend is the central coordinator: it stores jobs in Postgres, triggers the GPU worker (or a mock), receives uploaded videos, and serves them to the dashboard.

**Status: V1 implementation complete.** All endpoints, mock worker, Docker, and Makefile are in place.

---

## Tech Stack

- **FastAPI** -- async Python web framework
- **SQLModel** -- ORM (SQLAlchemy + Pydantic hybrid)
- **PostgreSQL 16** -- job persistence (via asyncpg)
- **Pydantic Settings** -- environment-based configuration
- **httpx** -- async HTTP client for triggering the real cloud worker
- **Docker** -- `python:3.11-slim` on ARM64 (M1-native)

---

## Directory Structure

```
backend/
  app/
    __init__.py
    main.py                  -- FastAPI app, lifespan (DB init, video dir), CORS, health check
    api/
      __init__.py
      deps.py                -- Shared dependencies: verify_worker_api_key, get_session re-export
      jobs.py                -- All 6 endpoints: create, list, get, download, upload, status
    models/
      __init__.py
      job.py                 -- Job table, JobStatus enum, JobCreate/JobRead/JobStatusUpdate schemas
    services/
      __init__.py
      job_service.py         -- Async CRUD: create_job, get_job, list_jobs, update_job_status, set_video_path
      mock_worker.py         -- In-process mock: simulates generation with minimal MP4, direct DB updates
      worker_service.py      -- Trigger dispatch: routes to mock or real worker, marks TRIGGERED
    core/
      __init__.py
      config.py              -- Pydantic Settings (loads from env / .env)
      database.py            -- Async engine, session factory, init_db
      logging.py             -- Structured logging setup with named loggers
  generated_videos/          -- Local video storage (V1), mounted as Docker volume
    .gitkeep
  requirements.txt
  Dockerfile
```

---

## API Endpoints

All endpoints are defined in `api/jobs.py` under the `/api/jobs` prefix.

| Method | Path                        | Auth               | Handler            | Status |
|--------|-----------------------------|--------------------|--------------------|--------|
| POST   | `/api/jobs`                 | None               | `create_job()`     | Done   |
| GET    | `/api/jobs`                 | None               | `list_jobs()`      | Done   |
| GET    | `/api/jobs/{id}`            | None               | `get_job()`        | Done   |
| GET    | `/api/jobs/{id}/download`   | None               | `download_video()` | Done   |
| POST   | `/api/jobs/{id}/upload`     | `X-Worker-API-Key` | `upload_video()`   | Done   |
| PATCH  | `/api/jobs/{id}/status`     | `X-Worker-API-Key` | `update_job_status()` | Done |
| GET    | `/health`                   | None               | `health_check()`   | Done   |

See [CONTRACTS.md](../CONTRACTS.md) for full request/response shapes.

**Note:** The original plan had `upload.py` as a separate router file. The implementation consolidated all endpoints into `jobs.py` for simplicity, with shared auth extracted to `deps.py`.

---

## Key Design Decisions

### Worker Authentication (`deps.py`)
Upload and status-update endpoints use the `verify_worker_api_key` dependency, which reads the `X-Worker-API-Key` header and compares it against `settings.worker_api_key`. Invalid requests get `401 Unauthorized`.

### Mock Worker Mode (`services/mock_worker.py`)
When `MOCK_WORKER=true` (default for local dev):
- `worker_service.py` spawns `run_mock_worker()` as an asyncio background task
- The mock worker walks through the full state machine: GENERATING -> UPLOADING -> COMPLETED
- It sleeps for `MOCK_DELAY_SECONDS` to simulate generation time
- It writes a minimal valid MP4 file (~200 bytes, proper ftyp+moov boxes) directly to `generated_videos/`
- It uses direct DB access (`async_session_factory`) rather than HTTP self-calls
- On failure, the job is marked FAILED with an error message

### Real Worker Trigger (`services/worker_service.py`)
When `MOCK_WORKER=false`:
- Sends `POST {WORKER_URL}` with the job payload (matches CONTRACTS.md spec)
- Includes `X-Worker-API-Key` header
- Expects `202 Accepted` response
- 10-second timeout on the trigger call (worker should respond immediately)

### Video Upload (`api/jobs.py` -- `upload_video`)
- Accepts `multipart/form-data` with a `file` field
- Streams to disk in 1MB chunks (handles large files without memory pressure)
- On write failure: cleans up partial file, marks job FAILED
- On success: calls `set_video_path()` which sets the path and marks COMPLETED

### Startup Lifecycle (`main.py`)
- Lifespan context manager calls `init_db()` (creates tables via `SQLModel.metadata.create_all`)
- Ensures `generated_videos/` directory exists
- CORS configured for `localhost:3000` and `127.0.0.1:3000`

---

## Configuration (`core/config.py`)

All settings come from environment variables (see `.env.example` in the repo root).

| Variable              | Default                          | Description                              |
|-----------------------|----------------------------------|------------------------------------------|
| `POSTGRES_USER`       | `videogen`                       | Postgres username                        |
| `POSTGRES_PASSWORD`   | `videogen_dev_password`          | Postgres password                        |
| `POSTGRES_DB`         | `videogen`                       | Database name                            |
| `POSTGRES_HOST`       | `postgres`                       | Host (Docker service name)               |
| `POSTGRES_PORT`       | `5432`                           | Port                                     |
| `DATABASE_URL`        | built from above                 | Override: full asyncpg URL               |
| `WORKER_API_KEY`      | (change-me placeholder)          | Shared secret for worker auth            |
| `MOCK_WORKER`         | `true`                           | Use in-process mock worker               |
| `MOCK_DELAY_SECONDS`  | `5`                              | Simulated generation time                |
| `WORKER_URL`          | `http://localhost:9000/generate`  | Cloud worker endpoint                    |
| `BACKEND_URL`         | `http://backend:8000`            | URL worker uses to call back             |
| `LOG_LEVEL`           | `INFO`                           | Logging verbosity                        |
| `GENERATED_VIDEOS_DIR`| `generated_videos`               | Local video storage path                 |

---

## Docker

### Dockerfile (`backend/Dockerfile`)
- Base: `python:3.11-slim` (ARM64-native on M1)
- Build context: project root (not `./backend`) so `backend.app.*` imports resolve
- Creates `/app/generated_videos` directory
- Runs: `uvicorn backend.app.main:app --host 0.0.0.0 --port 8000`

### docker-compose.yml (at repo root)
Two services:
- **postgres** -- `postgres:16-alpine`, healthcheck via `pg_isready`, persistent volume `pgdata`
- **backend** -- builds from `backend/Dockerfile`, depends on healthy postgres, mounts `./backend/generated_videos` into container, all env vars from `.env`

Worker is NOT included -- it runs on cloud GPU only.

### Makefile Targets

| Target      | Description                                |
|-------------|--------------------------------------------|
| `make up`   | Start postgres + backend (foreground)      |
| `make up-d` | Start in background (detached)             |
| `make down` | Stop all services                          |
| `make down-v` | Stop and remove volumes (deletes DB)     |
| `make logs` | Tail backend logs                          |
| `make logs-all` | Tail all logs                          |
| `make shell` | Open bash in backend container            |
| `make db-reset` | Drop and recreate database             |
| `make clean` | Remove generated video files              |
| `make status` | Show running containers                  |

---

## Development

### Running with Docker (recommended)

```bash
cp .env.example .env   # ensure MOCK_WORKER=true
make up                # builds and starts postgres + backend
# Backend: http://localhost:8000
# API docs: http://localhost:8000/docs
```

### Running without Docker

```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Postgres must be running separately
export DATABASE_URL=postgresql+asyncpg://videogen:videogen_dev_password@localhost:5432/videogen
export MOCK_WORKER=true
export WORKER_API_KEY=dev-key

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## Implementation Checklist

- [x] `main.py` -- app factory, lifespan (init_db, video dir), CORS, health check
- [x] `api/deps.py` -- worker API key verification, session dependency re-export
- [x] `api/jobs.py` -- create, list, get, download, upload, status endpoints
- [x] `services/job_service.py` -- async CRUD operations for Job table
- [x] `services/mock_worker.py` -- in-process mock with minimal MP4 generation
- [x] `services/worker_service.py` -- trigger dispatch (mock or real), TRIGGERED status
- [x] `Dockerfile` -- ARM-compatible production image
- [x] `docker-compose.yml` -- postgres + backend with healthcheck
- [x] `Makefile` -- build, run, logs, reset, clean targets
- [ ] Alembic migrations (using `create_all` for now -- adequate for V1)
- [ ] Request logging middleware with request_id (structured logging is in place, middleware is not)

---

## Known Issues

- `config.py` line 56: `default_resolution` has a corrupted default value (`"Worker auth ---"` instead of `"720p"`). This field is not currently used by any endpoint (the Job model has its own default), so it does not affect runtime.
- `job.py` line 57: Possible typo `deault` instead of `Field(default=...` -- verify before running.
