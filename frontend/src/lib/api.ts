/**
 * Typed API client for the video generation backend.
 * All functions read NEXT_PUBLIC_API_URL from process.env.
 */

import { Job, JobCreate } from "./types";

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_URL}${path}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...options?.headers,
    },
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new ApiError(
      res.status,
      body.detail ?? `Request failed (${res.status})`,
    );
  }

  return res.json() as Promise<T>;
}

/** Create a new video generation job. */
export async function createJob(data: JobCreate): Promise<Job> {
  return request<Job>("/api/jobs", {
    method: "POST",
    body: JSON.stringify(data),
  });
}

/** Fetch all jobs (newest first). */
export async function fetchJobs(): Promise<Job[]> {
  return request<Job[]>("/api/jobs");
}

/** Fetch a single job by ID. */
export async function fetchJob(id: string): Promise<Job> {
  return request<Job>(`/api/jobs/${id}`);
}

/** Build the download URL for a completed job's video. */
export function getDownloadUrl(jobId: string): string {
  return `${API_URL}/api/jobs/${jobId}/download`;
}
