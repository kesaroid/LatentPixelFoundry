# Backend -- FastAPI Video Generation Service

The backend is the central coordinator: it stores jobs in Postgres, triggers the GPU worker, receives uploaded videos, and serves them to the dashboard.

---

## Tech Stack

- **FastAPI** -- async Python web framework
- **SQLModel** -- ORM (SQLAlchemy + Pydantic hybrid)
- **PostgreSQL** -- job persistence (via asyncpg)
- **Pydantic Settings** -- environment-based configuration
- **httpx** -- async HTTP client for triggering the worker
- **Docker** -- `python:3.11-slim` on ARM64

---

## Directory Structure

```
backend/
  app/
    __init__.py
    main.py                  <-- FastAPI app, lifespan, router includes
    api/
      __init__.py
      jobs.py                <-- POST/GET /api/jobs, GET download
      upload.py              <-- POST /api/jobs/{id}/upload (worker -> backend)
    models/
      __init__.py
      job.py                 <-- Job table, JobStatus enum, Pydantic schemas
    services/
      __init__.py
      worker_trigger.py      <-- Trigger real worker or mock worker
    core/
      __init__.py
      config.py              <-- Pydantic Settings (loads .env)
      database.py            <-- Async engine, session factory, init_db
      logging.py             <-- Structured logging setup
  generated_videos/          <-- Local video storage (V1)
  requirements.txt
  Dockerfile
```

---

## API Endpoints

| Method | Path                        | Auth               | Handler          |
|--------|-----------------------------|--------------------|--------------------|
| POST   | `/api/jobs`                 | None               | `jobs.py`        |
| GET    | `/api/jobs`                 | None               | `jobs.py`        |
| GET    | `/api/jobs/{id}`            | None               | `jobs.py`        |
| GET    | `/api/jobs/{id}/download`   | None               | `jobs.py`        |
| POST   | `/api/jobs/{id}/upload`     | `X-Worker-API-Key` | `upload.py`      |
| PATCH  | `/api/jobs/{id}/status`     | `X-Worker-API-Key` | `upload.py`      |

See [CONTRACTS.md](../CONTRACTS.md) for full request/response shapes.

---

## Key Design Decisions

### Worker Authentication
Upload and status-update endpoints require `X-Worker-API-Key` header. The value is checked against `WORKER_API_KEY` from the environment. Requests without a valid key receive `401 Unauthorized`.

### Mock Worker Mode
When `MOCK_WORKER=true` (default for local dev):
- The `worker_trigger` service does NOT call an external URL
- Instead, it runs an asyncio background task that:
  1. Sleeps for `MOCK_DELAY_SECONDS` (simulating generation time)
  2. Updates job status through the state machine (GENERATING -> UPLOADING -> COMPLETED)
  3. Writes a minimal placeholder MP4 to `generated_videos/`
- This allows the full flow to be tested on M1 without a GPU

### Video Storage (V1)
Videos are stored as local files at `generated_videos/{job_id}.mp4`. The download endpoint streams them with `FileResponse`. This will be replaced by object storage URLs in V2.

### Database Initialization
On startup, `SQLModel.metadata.create_all` creates tables if they don't exist. For production, switch to Alembic migrations.

---

## Configuration

All settings come from environment variables (see `.env.example` in the repo root). Key backend variables:

| Variable              | Default                    | Description                            |
|-----------------------|----------------------------|----------------------------------------|
| `DATABASE_URL`        | built from POSTGRES_* vars | asyncpg connection string              |
| `WORKER_API_KEY`      | (required)                 | Shared secret for worker auth          |
| `MOCK_WORKER`         | `true`                     | Use in-process mock instead of real worker |
| `MOCK_DELAY_SECONDS`  | `5`                        | Simulated generation time              |
| `WORKER_URL`          | `http://localhost:9000/generate` | Cloud worker endpoint             |
| `BACKEND_URL`         | `http://backend:8000`      | URL the worker uses to call back       |
| `LOG_LEVEL`           | `INFO`                     | Logging verbosity                      |

---

## Development

### Running Locally (Docker)

From the repo root:

```bash
cp .env.example .env   # edit MOCK_WORKER=true
make up                # starts postgres + backend
```

Backend will be at `http://localhost:8000`. Interactive API docs at `http://localhost:8000/docs`.

### Running Without Docker

```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Start Postgres separately, then:
export DATABASE_URL=postgresql+asyncpg://videogen:videogen_dev_password@localhost:5432/videogen
export MOCK_WORKER=true
export WORKER_API_KEY=dev-key

uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## Implementation Checklist

- [ ] `main.py` -- app factory, lifespan (init_db), include routers, CORS
- [ ] `api/jobs.py` -- create, list, get, download endpoints
- [ ] `api/upload.py` -- streaming upload + status update with API key guard
- [ ] `services/worker_trigger.py` -- trigger real worker or mock
- [ ] `Dockerfile` -- ARM-compatible production image
- [ ] Error handling: catch exceptions, set FAILED status, log with job_id
- [ ] Structured request logging middleware
