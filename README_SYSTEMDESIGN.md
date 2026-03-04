# LatentPixelFoundry

AI video generation from text prompts. Submit a prompt, a cloud GPU worker generates the video, and you download it from a local dashboard.

**Project Status: V1 implementation complete across all three feature branches.** Backend, frontend, and worker are each fully built and ready to merge.

---

## Architecture (V1)

```
                         Local (M1 ARM)                          Cloud (x86 CUDA)
                 +---------------------------------+       +---------------------+
                 |                                 |       |                     |
  User -------> | Next.js       FastAPI   Postgres |       |    GPU Worker       |
  (browser)     | Dashboard --> Backend --> [jobs]  | ----> |  (CogVideoX-2b,    |
                 |              |    ^              |       |   Dockerized)       |
                 |              |    |              |       |         |           |
                 |              v    |  POST /upload|       +---------|----------+
                 |         generated_videos/ <------+----------------+
                 |                                 |
                 +---------------------------------+
```

**V1 Flow:**

1. User submits text prompt from Dashboard
2. Backend creates job in Postgres (PENDING)
3. Backend triggers cloud GPU worker (or mock worker locally)
4. Worker generates video with CogVideoX-2b, streams it back via `POST /api/jobs/{id}/upload`
5. Backend stores video at `backend/generated_videos/{job_id}.mp4`
6. Backend marks job COMPLETED
7. Dashboard polls every 5 seconds and shows download link
8. User manually uploads to Instagram

**V1 boundaries:** No object storage. No Instagram automation. No auth. No queue.

---

## Current Branch Status

| Branch             | Status    | What's Built                                                           |
|--------------------|-----------|------------------------------------------------------------------------|
| `master`           | Scaffold  | Shared contracts, Job model, config, database, docs, .env, .gitignore  |
| `feature/backend`  | Complete  | FastAPI app (6 endpoints), mock worker, Docker, Makefile               |
| `feature/frontend` | Complete  | Next.js 16 dashboard, all components, polling, dark theme              |
| `feature/worker`   | Complete  | CogVideoX-2b worker, backend client with retry, CUDA Dockerfile       |

### Merge Order

All three branches fork from the same scaffold commit. Merge into `master`:

```bash
cd /Users/kesaroid/Documents/Projects/LatentPixelFoundry
git merge feature/backend      # backend/, docker-compose.yml, Makefile
git merge feature/frontend     # frontend/
git merge feature/worker       # worker/
```

Each branch primarily touches its own directory. The only shared file is `backend/app/models/job.py` (unchanged from scaffold in all branches).

---

## Repository Layout

```
LatentPixelFoundry/
  CONTRACTS.md                   -- API interface spec (shared contract)
  V2.md                          -- Future architecture roadmap
  .env.example                   -- Environment variable template
  .gitignore
  docker-compose.yml             -- Postgres + Backend (from feature/backend)
  Makefile                       -- Dev commands (from feature/backend)

  backend/                       -- FastAPI service (from feature/backend)
    app/
      main.py                    -- App factory, lifespan, CORS, health
      api/
        deps.py                  -- API key verification, session dep
        jobs.py                  -- All 6 job endpoints
      models/
        job.py                   -- Job table, status enum, Pydantic schemas
      services/
        job_service.py           -- Async CRUD for Job table
        mock_worker.py           -- In-process mock (minimal MP4)
        worker_service.py        -- Trigger dispatch (mock or real)
      core/
        config.py                -- Pydantic Settings
        database.py              -- Async engine + session factory
        logging.py               -- Structured logging
    generated_videos/            -- Local video storage (V1)
    Dockerfile                   -- python:3.11-slim, ARM64
    requirements.txt

  frontend/                      -- Next.js dashboard (from feature/frontend)
    src/
      app/
        layout.tsx               -- Root layout, Geist fonts, dark mode
        page.tsx                 -- Main page: form + job list
        globals.css              -- Tailwind + CSS vars
      components/
        PromptForm.tsx           -- Prompt input, duration, resolution, submit
        JobList.tsx              -- Job cards, skeletons, empty/error states
        JobCard.tsx              -- Status, prompt, meta, download button
        StatusBadge.tsx          -- Color-coded status pills
      hooks/
        useJobs.ts               -- 5-second polling hook
      lib/
        api.ts                   -- Typed HTTP client
        types.ts                 -- TypeScript types mirroring backend
    .env.local.example
    package.json                 -- Next.js 16, React 19, Tailwind 4

  worker/                        -- GPU worker (from feature/worker)
    worker.py                    -- FastAPI: /health, /generate, background task
    model_loader.py              -- CogVideoX-2b lazy singleton
    backend_client.py            -- HTTP client with retry for backend callbacks
    config.py                    -- WorkerSettings
    Dockerfile                   -- CUDA 12.1, Python 3.11, x86_64 only
    requirements.txt             -- torch, diffusers, accelerate, etc.
```

---

## Git Worktrees

This project uses **git worktrees** for parallel development. Three worktrees allow separate agents (or developers) to build the frontend, backend, and worker simultaneously.

### Worktree Map

| Directory                        | Branch             | Scope                                          |
|----------------------------------|--------------------|-------------------------------------------------|
| `LatentPixelFoundry/`            | `master`           | Scaffold, shared contracts, docs, Docker config |
| `LatentPixelFoundry-frontend/`   | `feature/frontend` | Next.js dashboard                               |
| `LatentPixelFoundry-backend/`    | `feature/backend`  | FastAPI service, mock worker, Docker infra       |
| `LatentPixelFoundry-worker/`     | `feature/worker`   | GPU worker, model loader                         |

### Opening a Worktree

```bash
cursor /Users/kesaroid/Documents/Projects/LatentPixelFoundry-frontend
cursor /Users/kesaroid/Documents/Projects/LatentPixelFoundry-backend
cursor /Users/kesaroid/Documents/Projects/LatentPixelFoundry-worker
```

### Cleaning Up Worktrees (after merge)

```bash
cd /Users/kesaroid/Documents/Projects/LatentPixelFoundry
git worktree remove ../LatentPixelFoundry-frontend
git worktree remove ../LatentPixelFoundry-backend
git worktree remove ../LatentPixelFoundry-worker
git branch -d feature/frontend feature/backend feature/worker
```

---

## Job Status State Machine

```
PENDING --> TRIGGERED --> GENERATING --> UPLOADING --> COMPLETED
                                                 \--> FAILED
Any state can also transition to FAILED on error.
```

| Status     | Set By  | Meaning                          |
|------------|---------|----------------------------------|
| PENDING    | Backend | Job created, not yet triggered    |
| TRIGGERED  | Backend | Worker has been notified          |
| GENERATING | Worker  | Video generation in progress      |
| UPLOADING  | Worker  | Generation done, uploading video  |
| COMPLETED  | Backend | Video received and stored locally |
| FAILED     | Either  | Error occurred at any stage       |

---

## API Endpoints

| Method | Endpoint                    | Auth               | Description                        |
|--------|-----------------------------|--------------------|------------------------------------|
| POST   | `/api/jobs`                 | None               | Create a new job                   |
| GET    | `/api/jobs`                 | None               | List all jobs (newest first)       |
| GET    | `/api/jobs/{id}`            | None               | Get single job                     |
| GET    | `/api/jobs/{id}/download`   | None               | Download generated video           |
| POST   | `/api/jobs/{id}/upload`     | `X-Worker-API-Key` | Worker uploads video (streaming)   |
| PATCH  | `/api/jobs/{id}/status`     | `X-Worker-API-Key` | Worker updates job status          |
| GET    | `/health`                   | None               | Backend liveness probe             |
| GET    | `/health` (worker:9000)     | None               | Worker readiness probe             |
| POST   | `/generate` (worker:9000)   | None               | Backend triggers worker            |

Full request/response shapes in [CONTRACTS.md](CONTRACTS.md).

---

## Docker Strategy

| Component | Base Image                              | Platform    | Runs Where    |
|-----------|-----------------------------------------|-------------|---------------|
| Backend   | `python:3.11-slim`                      | linux/arm64 | Local (M1)    |
| Postgres  | `postgres:16-alpine`                    | linux/arm64 | Local (M1)    |
| Frontend  | Run natively (`npm run dev`)            | --          | Local          |
| Worker    | `nvidia/cuda:12.1.1-runtime-ubuntu22.04`| linux/amd64 | Cloud GPU     |

The backend and Postgres run in ARM-native containers on M1. The worker uses an x86 CUDA image and **never runs locally**. During local development, `MOCK_WORKER=true` simulates the worker in-process with a 5-second delay and a minimal placeholder MP4.

---

## Local Development

### Prerequisites

- Docker Desktop for Mac (ARM)
- Node.js 20+
- Python 3.11+ (only if running backend outside Docker)

### Quick Start

```bash
# 1. Merge all feature branches first (see Merge Order above)

# 2. Copy and configure environment
cp .env.example .env
# MOCK_WORKER=true is already the default

# 3. Start Postgres + Backend
make up

# 4. Start Frontend (separate terminal)
cd frontend && npm install && npm run dev

# 5. Open
#   Dashboard:  http://localhost:3000
#   Backend:    http://localhost:8000
#   API docs:   http://localhost:8000/docs
```

### Makefile Targets

| Target       | Description                              |
|--------------|------------------------------------------|
| `make up`    | Start Postgres + Backend (foreground)    |
| `make up-d`  | Start in background                      |
| `make down`  | Stop all containers                      |
| `make down-v`| Stop and remove volumes (deletes DB)     |
| `make logs`  | Tail backend logs                        |
| `make shell` | Open bash in backend container           |
| `make db-reset` | Drop and recreate database            |
| `make clean` | Remove generated video files             |
| `make status`| Show running containers                  |

---

## Production Deployment

- **Backend:** ARM VM (AWS Graviton, etc.) or any Docker host
- **Worker:** GPU instance (x86, NVIDIA GPU, CUDA drivers, NVIDIA Container Toolkit)
- **Postgres:** Managed service (RDS, etc.) or dedicated instance
- Set `MOCK_WORKER=false` and `WORKER_URL` to the cloud worker endpoint
- Use a secrets manager for `WORKER_API_KEY`
- Ensure `generated_videos/` directory has sufficient disk space
- Consider a reverse proxy (nginx/caddy) for large file upload timeout tuning
- Worker model (`THUDM/CogVideoX-2b`) downloads on first run -- pre-cache for faster cold starts

---

## Security

- Worker authenticates to backend via `X-Worker-API-Key` header
- Upload and status-update endpoints reject requests without a valid key
- All secrets live in `.env` (never committed -- see `.env.example`)
- Frontend has no authentication in V1

---

## Error Handling

- Jobs transition to FAILED on: worker timeout, upload failure, generation exception, CUDA OOM
- `error_message` column stores the failure reason (up to 4000 chars)
- Worker retries backend calls with exponential backoff (3 attempts, 2s base delay)
- Structured logging with job_id context throughout backend and worker
- Temp files always cleaned up in worker's `finally` block

---

## Related Documents

- [CONTRACTS.md](CONTRACTS.md) -- Full API request/response contracts
- [V2.md](V2.md) -- Future architecture and enhancement roadmap
- [backend/README.md](backend/README.md) -- Backend development guide
- [frontend/README.md](frontend/README.md) -- Frontend development guide
- [worker/README.md](worker/README.md) -- Worker development guide
