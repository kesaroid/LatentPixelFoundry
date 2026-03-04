# Frontend -- Video Generation Dashboard

A dark-themed Next.js dashboard for submitting video generation prompts, tracking job progress in real time, and downloading completed videos.

**Status: V1 implementation complete.** All components, API integration, polling, and styling are in place.

---

## Tech Stack

- **Next.js 16** -- App Router, React Server Components
- **React 19** -- Client components where needed
- **Tailwind CSS 4** -- Utility-first styling (dark theme)
- **TypeScript 5** -- Full type safety
- **Geist font** -- Clean, modern typography (via `next/font/google`)

---

## Directory Structure

```
frontend/
  src/
    app/
      layout.tsx             -- Root layout: Geist fonts, dark mode, metadata
      page.tsx               -- Main page: header, PromptForm, JobList
      globals.css            -- Tailwind import, CSS custom properties
    components/
      PromptForm.tsx         -- Prompt textarea, duration input, resolution select, submit
      JobList.tsx            -- Renders job cards, loading skeletons, empty state, error
      JobCard.tsx            -- Single job: status badge, prompt, meta, error, download
      StatusBadge.tsx        -- Color-coded pill per JobStatus with pulse animation
    hooks/
      useJobs.ts             -- 5-second polling hook: fetchJobs, loading, error, refetch
    lib/
      api.ts                 -- Typed HTTP client: createJob, fetchJobs, fetchJob, getDownloadUrl
      types.ts               -- TypeScript types mirroring backend schemas: Job, JobCreate, JobStatus
  .env.local.example         -- NEXT_PUBLIC_API_URL template
  .gitignore
  package.json
  tsconfig.json
  next.config.ts
  eslint.config.mjs
  postcss.config.mjs
```

**Note:** The implementation uses the `src/` directory convention (standard for Next.js) rather than the flat `app/` layout from the original plan. The prompt form component is named `PromptForm.tsx` rather than `JobForm.tsx`.

---

## Features

### Prompt Submission (`PromptForm.tsx`)
- Multi-line textarea with 2000-character limit and live counter
- Duration input (1-30 seconds, default 5)
- Resolution dropdown (720p, 1080p)
- Submit button with loading state ("Creating Job...")
- Inline error display on failure
- Form resets on successful submission
- Calls `POST /api/jobs` via the typed API client

### Job List (`JobList.tsx`)
- Displays all jobs sorted newest-first
- Three states:
  - **Loading:** Animated skeleton placeholders (3 pulse cards)
  - **Error:** Red-tinted error message
  - **Empty:** "No jobs yet" prompt
- Each job rendered as a `JobCard`

### Job Card (`JobCard.tsx`)
- Status badge (via `StatusBadge`)
- Relative timestamp ("2m ago", "1h ago")
- Prompt text (2-line clamp)
- Meta row: duration, resolution, generation time (if available)
- Error message display for FAILED jobs (red background)
- Download button for COMPLETED jobs (green, with download icon SVG)
- Download links to `GET /api/jobs/{id}/download`

### Status Badges (`StatusBadge.tsx`)
Color-coded pill badges with Tailwind classes:

| Status     | Color       | Extra           |
|------------|-------------|-----------------|
| PENDING    | Zinc/Gray   |                 |
| TRIGGERED  | Blue        |                 |
| GENERATING | Amber       | `animate-pulse` |
| UPLOADING  | Indigo      |                 |
| COMPLETED  | Emerald     |                 |
| FAILED     | Red         |                 |

### Polling (`useJobs.ts` hook)
- Initial fetch on mount
- Polls `GET /api/jobs` every 5 seconds via `setInterval`
- Exposes: `jobs`, `loading`, `error`, `refetch()`
- `refetch()` is called immediately after job creation for instant feedback
- Interval is cleaned up on unmount

### API Client (`lib/api.ts`)
- Reads `NEXT_PUBLIC_API_URL` from environment (default: `http://localhost:8000`)
- Generic `request<T>()` helper with error handling
- Custom `ApiError` class with status code
- Exported functions: `createJob()`, `fetchJobs()`, `fetchJob()`, `getDownloadUrl()`

### Type Definitions (`lib/types.ts`)
- `JobStatus` enum mirroring backend's `JobStatus`
- `JobCreate` interface (prompt, duration, resolution)
- `Job` interface (full response shape matching `JobRead`)

---

## Configuration

| Variable              | Default                  | Description                |
|-----------------------|--------------------------|----------------------------|
| `NEXT_PUBLIC_API_URL` | `http://localhost:8000`  | Backend API base URL       |

Set in `.env.local` (copy from `.env.local.example`).

---

## Development

### Running Locally

```bash
cd frontend
cp .env.local.example .env.local  # optional, defaults work for local dev
npm install
npm run dev
```

Dashboard at `http://localhost:3000`. Requires the backend running at `http://localhost:8000`.

### Build

```bash
npm run build
npm start         # production server on port 3000
```

---

## Design Choices

- **Dark theme only.** CSS custom properties set `--background: #09090b` and `--foreground: #fafafa`. The `<html>` element gets `class="dark"`.
- **No state management library.** React `useState` + the `useJobs` polling hook cover everything needed for V1.
- **No authentication.** V1 is a single-user local tool.
- **No WebSocket.** Simple 5-second polling is sufficient for the update frequency.
- **Minimal dependencies.** Only Next.js, React, and Tailwind. No UI component library.

---

## Implementation Checklist

- [x] `layout.tsx` -- Root layout with Tailwind, Geist fonts, dark mode, metadata
- [x] `page.tsx` -- Main page composing PromptForm + JobList
- [x] `PromptForm.tsx` -- Prompt textarea, duration/resolution, submit with loading/error
- [x] `JobList.tsx` -- Loading skeletons, error state, empty state, job cards
- [x] `JobCard.tsx` -- Status badge, prompt, timestamps, meta row, error, download
- [x] `StatusBadge.tsx` -- Color-coded pills with pulse animation for GENERATING
- [x] `useJobs.ts` -- 5-second polling hook with refetch
- [x] `api.ts` -- Typed API client with error handling
- [x] `types.ts` -- TypeScript types mirroring backend schemas
- [x] `globals.css` -- Tailwind + CSS custom properties
- [x] `package.json` -- Next.js 16, React 19, Tailwind 4
- [x] `.env.local.example` -- API URL template
- [ ] Dockerfile -- Not yet created (run natively via `npm run dev` for now)
- [ ] Toast/notification for successful job creation (currently just clears form)
