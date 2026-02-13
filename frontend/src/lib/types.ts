/**
 * Type definitions mirroring the backend Pydantic schemas.
 * See: backend/app/models/job.py and CONTRACTS.md
 */

export enum JobStatus {
  PENDING = "PENDING",
  TRIGGERED = "TRIGGERED",
  GENERATING = "GENERATING",
  UPLOADING = "UPLOADING",
  COMPLETED = "COMPLETED",
  FAILED = "FAILED",
}

/** Request body for POST /api/jobs */
export interface JobCreate {
  prompt: string;
  duration: number;
  resolution: string;
}

/** Response schema returned by all job endpoints (mirrors JobRead). */
export interface Job {
  id: string;
  prompt: string;
  duration: number;
  resolution: string;
  status: JobStatus;
  video_path: string | null;
  generation_time_seconds: number | null;
  error_message: string | null;
  created_at: string;
  updated_at: string;
}
