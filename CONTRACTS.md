# API Contracts — V1

This document defines the interface contracts between Frontend, Backend, and Worker.
All three components MUST adhere to these contracts.

---

## Backend API Endpoints

### POST /api/jobs
Create a new video generation job.

**Request:**
```json
{
  "prompt": "A cat walking in the rain",
  "duration": 5,
  "resolution": "720p"
}
```

**Response (201):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "prompt": "A cat walking in the rain",
  "duration": 5,
  "resolution": "720p",
  "status": "PENDING",
  "video_path": null,
  "generation_time_seconds": null,
  "error_message": null,
  "created_at": "2026-02-12T10:00:00Z",
  "updated_at": "2026-02-12T10:00:00Z"
}
```

---

### GET /api/jobs
List all jobs (newest first).

**Response (200):**
```json
[
  { "id": "...", "prompt": "...", "status": "COMPLETED", ... },
  { "id": "...", "prompt": "...", "status": "GENERATING", ... }
]
```

---

### GET /api/jobs/{job_id}
Get a single job by ID.

**Response (200):** Same shape as single job above.
**Response (404):** `{ "detail": "Job not found" }`

---

### GET /api/jobs/{job_id}/download
Download the generated video file.

**Response (200):** Binary MP4 stream with `Content-Type: video/mp4`
**Response (404):** `{ "detail": "Job not found" }` or `{ "detail": "Video not available" }`

---

### POST /api/jobs/{job_id}/upload
Worker uploads generated video. **Requires `X-Worker-API-Key` header.**

**Request:** `multipart/form-data` with field `file` (the MP4 video)
**Response (200):** `{ "status": "ok", "video_path": "generated_videos/{job_id}.mp4" }`
**Response (401):** `{ "detail": "Invalid API key" }`

---

### PATCH /api/jobs/{job_id}/status
Worker updates job status. **Requires `X-Worker-API-Key` header.**

**Request:**
```json
{
  "status": "GENERATING",
  "error_message": null,
  "generation_time_seconds": null
}
```

**Response (200):** Updated job object.
**Response (401):** `{ "detail": "Invalid API key" }`

---

## Worker Trigger Contract

Backend triggers the worker via **POST {WORKER_URL}** with:

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "prompt": "A cat walking in the rain",
  "duration": 5,
  "resolution": "720p",
  "backend_url": "http://backend:8000",
  "upload_url": "http://backend:8000/api/jobs/550e8400-.../upload",
  "status_url": "http://backend:8000/api/jobs/550e8400-.../status"
}
```

Worker must respond immediately with `202 Accepted` and process asynchronously.

---

## Job Status State Machine

```
PENDING -> TRIGGERED -> GENERATING -> UPLOADING -> COMPLETED
                                               \-> FAILED
Any state can transition to FAILED on error.
```

| Status     | Set By   | Meaning                           |
|------------|----------|-----------------------------------|
| PENDING    | Backend  | Job created, not yet triggered     |
| TRIGGERED  | Backend  | Worker has been notified           |
| GENERATING | Worker   | Video generation in progress       |
| UPLOADING  | Worker   | Generation done, uploading video   |
| COMPLETED  | Backend  | Video received and stored          |
| FAILED     | Either   | Something went wrong               |

---

## Authentication

Worker -> Backend requests must include header:
```
X-Worker-API-Key: <value of WORKER_API_KEY env var>
```

Frontend -> Backend requests require no authentication in V1.

---

## Environment Variables (shared)

See `.env.example` for the full list.
Key variables each component needs:

| Variable        | Backend | Worker | Frontend |
|-----------------|---------|--------|----------|
| DATABASE_URL    | yes     | no     | no       |
| WORKER_API_KEY  | yes     | yes    | no       |
| WORKER_URL      | yes     | no     | no       |
| BACKEND_URL     | no      | yes    | no       |
| MOCK_WORKER     | yes     | no     | no       |
| NEXT_PUBLIC_API_URL | no  | no     | yes      |
