# LatentPixelFoundry

AI video generation from text prompts. Submit a prompt, a cloud GPU worker generates the video, and you download it from a local dashboard.

## Architecture (V1)

```
                         Local (M1 ARM)                          Cloud (x86 CUDA)
                 +---------------------------------+       +---------------------+
                 |                                 |       |                     |
  User -------> | Next.js       FastAPI   Postgres |       |    GPU Worker       |
  (browser)     | Dashboard --> Backend --> [jobs]  | ----> |  (Dockerized,       |
                 |              |    ^              |       |   generates video)  |
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
4. Worker generates video, streams it back via `POST /api/jobs/{id}/upload`
5. Backend stores video at `backend/generated_videos/{job_id}.mp4`
6. Backend marks job COMPLETED
7. Dashboard polls and shows download link
8. User manually uploads to Instagram

**V1 boundaries:** No object storage. No Instagram automation. No auth. No queue.

---

## Repository Layout

```
LatentPixelFoundry/              <-- master (this repo)
  CONTRACTS.md                   <-- shared API contracts
  V2.md                          <-- future architecture doc
  .env.example
  backend/
    app/
      core/                      <-- config, database, logging
      models/                    <-- Job model (shared contract)
      api/                       <-- FastAPI endpoints
      services/                  <-- worker trigger, mock worker
    generated_videos/
    Dockerfile
    requirements.txt
  frontend/
    app/                         <-- Next.js pages
    components/                  <-- React components
    Dockerfile
    package.json
  worker/
    worker.py                    <-- GPU generation entry point
    model_loader.py              <-- AI model loading
    Dockerfile
    requirements.txt
  docker-compose.yml
  Makefile
```

---

## Parallel Development with Git Worktrees

This project uses **git worktrees** so three agents (or developers) can build the frontend, backend, and worker simultaneously on isolated branches without conflicts.

### Worktree Map

| Directory                        | Branch             | Scope                                     |
|----------------------------------|--------------------|--------------------------------------------|
| `LatentPixelFoundry/`            | `master`           | Scaffold, shared contracts, docs, Docker   |
| `LatentPixelFoundry-frontend/`   | `feature/frontend` | Next.js dashboard, components, styling     |
| `LatentPixelFoundry-backend/`    | `feature/backend`  | FastAPI endpoints, services, mock worker   |
| `LatentPixelFoundry-worker/`     | `feature/worker`   | GPU worker, model loading, Dockerfile      |

All three branches fork from the same scaffold commit on `master`, which contains:
- Directory structure with `__init__.py` stubs
- `CONTRACTS.md` -- the API interface spec all components must follow
- `backend/app/models/job.py` -- shared Job model and Pydantic schemas
- `backend/app/core/` -- config, database, logging modules
- `requirements.txt` for backend and worker
- `.env.example` and `.gitignore`

### Opening a Worktree in Cursor

```bash
cursor /Users/kesaroid/Documents/Projects/LatentPixelFoundry-frontend
cursor /Users/kesaroid/Documents/Projects/LatentPixelFoundry-backend
cursor /Users/kesaroid/Documents/Projects/LatentPixelFoundry-worker
```

Each opens as a separate Cursor window. Launch an agent in each to work in parallel.

### Merging Back

When all three features are complete, merge into `master` from the main repo:

```bash
cd /Users/kesaroid/Documents/Projects/LatentPixelFoundry

git merge feature/backend
git merge feature/frontend
git merge feature/worker
```

Since each branch primarily touches its own directory (`backend/`, `frontend/`, `worker/`), merges should be conflict-free. The only shared file is `backend/app/models/job.py`, which should not need changes after the scaffold.

### Cleaning Up Worktrees

After merging:

```bash
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

## Database Schema

**Table: `jobs`**

| Column                   | Type     | Constraints               |
|--------------------------|----------|---------------------------|
| id                       | UUID     | PK, default uuid4         |
| prompt                   | String   | NOT NULL                  |
| duration                 | Integer  | NOT NULL, default 5       |
| resolution               | String   | NOT NULL, default "720p"  |
| status                   | Enum     | NOT NULL, default PENDING |
| video_path               | String   | NULLABLE                  |
| generation_time_seconds  | Float    | NULLABLE                  |
| error_message            | String   | NULLABLE                  |
| created_at               | DateTime | default utcnow            |
| updated_at               | DateTime | default utcnow, onupdate  |

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

Full request/response shapes are documented in [CONTRACTS.md](CONTRACTS.md).

---

## Docker Strategy

| Component | Base Image                              | Platform    | Runs Where    |
|-----------|-----------------------------------------|-------------|---------------|
| Backend   | `python:3.11-slim`                      | linux/arm64 | Local (M1)    |
| Postgres  | `postgres:16-alpine`                    | linux/arm64 | Local (M1)    |
| Frontend  | `node:20-alpine`                        | linux/arm64 | Local (M1)    |
| Worker    | `nvidia/cuda:12.1-runtime-ubuntu22.04`  | linux/amd64 | Cloud GPU     |

The backend and Postgres run in ARM-native containers on M1. The worker uses an x86 CUDA image and **never runs locally** -- it is deployed to a cloud GPU instance. During local development, set `MOCK_WORKER=true` to simulate the worker in-process.

---

## Local Development

### Prerequisites

- Docker Desktop for Mac (ARM)
- Node.js 20+
- Python 3.11+

### Quick Start

```bash
# 1. Copy and configure environment
cp .env.example .env
# Edit .env -- set MOCK_WORKER=true for local development

# 2. Start Postgres + Backend
make up

# 3. Start Frontend (separate terminal)
cd frontend && npm install && npm run dev

# 4. Open
#   Dashboard:  http://localhost:3000
#   Backend:    http://localhost:8000
#   API docs:   http://localhost:8000/docs
```

### Makefile Targets

| Target       | Description                              |
|--------------|------------------------------------------|
| `make up`    | Start Postgres + Backend containers      |
| `make down`  | Stop all containers                      |
| `make logs`  | Tail container logs                      |
| `make build` | Rebuild Docker images                    |
| `make clean` | Stop containers and remove volumes       |

---

## Production Deployment

- **Backend:** ARM VM (AWS Graviton, etc.) or any Docker host
- **Worker:** GPU instance (x86, NVIDIA GPU, CUDA drivers)
- **Postgres:** Managed service (RDS, etc.) or dedicated instance
- Set `MOCK_WORKER=false` and `WORKER_URL` to the cloud worker endpoint
- Use a secrets manager for `WORKER_API_KEY`
- Ensure `generated_videos/` directory has sufficient disk space
- Consider a reverse proxy (nginx/caddy) for large file upload timeout tuning

---

## Security

- Worker authenticates to backend via `X-Worker-API-Key` header
- Upload and status-update endpoints reject requests without a valid key
- All secrets live in `.env` (never committed -- see `.env.example`)
- Frontend has no authentication in V1

---

## Error Handling

- Jobs transition to FAILED on: worker timeout, upload failure, generation exception
- `error_message` column stores the failure reason
- Structured logging with job_id context throughout the backend
- Retry logic is a documented placeholder for V2 (not implemented in V1)

---

## Related Documents

- [CONTRACTS.md](CONTRACTS.md) -- Full API request/response contracts
- [V2.md](V2.md) -- Future architecture and enhancement roadmap
- [backend/README.md](backend/README.md) -- Backend development guide
- [frontend/README.md](frontend/README.md) -- Frontend development guide
- [worker/README.md](worker/README.md) -- Worker development guide
