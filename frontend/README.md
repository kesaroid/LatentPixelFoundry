# Frontend -- Video Generation Dashboard

A minimal Next.js dashboard for submitting video generation prompts, tracking job progress, and downloading completed videos.

---

## Tech Stack

- **Next.js 14** -- App Router
- **React 18** -- UI components
- **Tailwind CSS** -- Utility-first styling
- **TypeScript** -- Type safety

---

## Directory Structure

```
frontend/
  app/
    layout.tsx               <-- Root layout, fonts, metadata
    page.tsx                 <-- Main dashboard page
  components/
    JobForm.tsx              <-- Prompt input + submit button
    JobList.tsx              <-- Fetches and displays all jobs, polls every 5s
    JobCard.tsx              <-- Single job: status badge, download button
  package.json
  tailwind.config.ts
  tsconfig.json
  Dockerfile
```

---

## Features

### Prompt Submission
- Text input for the video prompt
- Optional duration selector (1-30 seconds, default 5)
- Optional resolution selector (720p, 1080p)
- Submit calls `POST /api/jobs` on the backend

### Job List
- Displays all jobs sorted newest-first
- Polls `GET /api/jobs` every 5 seconds for live status updates
- No WebSocket needed in V1 -- simple polling

### Status Badges
Each job shows a color-coded status badge:

| Status     | Color  |
|------------|--------|
| PENDING    | Gray   |
| TRIGGERED  | Blue   |
| GENERATING | Yellow |
| UPLOADING  | Orange |
| COMPLETED  | Green  |
| FAILED     | Red    |

### Video Download
- COMPLETED jobs show a download button
- Button links to `GET /api/jobs/{id}/download`
- Browser handles the MP4 download natively

### Error Display
- FAILED jobs show the error message from the backend
- Form validation for empty prompts

---

## API Integration

The frontend communicates with the backend at `NEXT_PUBLIC_API_URL` (default: `http://localhost:8000`).

| Action         | Method | Endpoint               |
|----------------|--------|------------------------|
| Create job     | POST   | `/api/jobs`            |
| List jobs      | GET    | `/api/jobs`            |
| Get job detail | GET    | `/api/jobs/{id}`       |
| Download video | GET    | `/api/jobs/{id}/download` |

See [CONTRACTS.md](../CONTRACTS.md) for full request/response shapes.

---

## Configuration

| Variable              | Default                  | Description                |
|-----------------------|--------------------------|----------------------------|
| `NEXT_PUBLIC_API_URL` | `http://localhost:8000`  | Backend API base URL       |

Set in `.env.local` or as an environment variable.

---

## Development

### Running Locally

```bash
cd frontend
npm install
npm run dev
```

Dashboard at `http://localhost:3000`. Requires the backend to be running at `http://localhost:8000`.

### Running in Docker (optional)

The Dockerfile is provided for consistency but during local development it's simpler to run `npm run dev` natively.

---

## Design Principles

- **Minimal UI.** No unnecessary chrome. Focus on the core flow: submit prompt, watch status, download video.
- **No client-side state management library.** React state + polling is sufficient for V1.
- **No authentication.** V1 is a single-user local tool.
- **Responsive.** Works on desktop. Mobile is not a priority but Tailwind keeps it reasonable.

---

## Implementation Checklist

- [ ] `layout.tsx` -- Root layout with Tailwind, metadata, font
- [ ] `page.tsx` -- Main page composing JobForm + JobList
- [ ] `JobForm.tsx` -- Prompt input, duration/resolution selectors, submit handler
- [ ] `JobList.tsx` -- Fetch jobs, 5-second polling interval, render JobCards
- [ ] `JobCard.tsx` -- Status badge, prompt text, timestamps, download button
- [ ] `package.json` -- Dependencies (next, react, tailwind)
- [ ] `tailwind.config.ts` + `globals.css` -- Tailwind setup
- [ ] `Dockerfile` -- node:20-alpine multi-stage build
- [ ] Error handling for failed API calls (toast or inline message)
