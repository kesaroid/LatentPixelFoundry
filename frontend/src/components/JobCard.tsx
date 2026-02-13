import { getDownloadUrl } from "@/lib/api";
import { Job, JobStatus } from "@/lib/types";

import { StatusBadge } from "./StatusBadge";

interface JobCardProps {
  job: Job;
}

/** Format an ISO date string as a relative time (e.g. "2m ago"). */
function timeAgo(isoString: string): string {
  const seconds = Math.floor(
    (Date.now() - new Date(isoString).getTime()) / 1000,
  );
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

export function JobCard({ job }: JobCardProps) {
  const isCompleted = job.status === JobStatus.COMPLETED;
  const isFailed = job.status === JobStatus.FAILED;

  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
      {/* Header: status + timestamp */}
      <div className="flex items-center justify-between gap-3">
        <StatusBadge status={job.status} />
        <span className="text-xs text-zinc-500" title={job.created_at}>
          {timeAgo(job.created_at)}
        </span>
      </div>

      {/* Prompt */}
      <p className="mt-3 text-sm leading-relaxed text-zinc-300 line-clamp-2">
        {job.prompt}
      </p>

      {/* Meta row */}
      <div className="mt-3 flex items-center gap-3 text-xs text-zinc-500">
        <span>{job.duration}s</span>
        <span className="text-zinc-700">&middot;</span>
        <span>{job.resolution}</span>
        {job.generation_time_seconds != null && (
          <>
            <span className="text-zinc-700">&middot;</span>
            <span>Generated in {job.generation_time_seconds.toFixed(1)}s</span>
          </>
        )}
      </div>

      {/* Error message */}
      {isFailed && job.error_message && (
        <p className="mt-3 rounded bg-red-950/50 px-3 py-2 text-xs text-red-400">
          {job.error_message}
        </p>
      )}

      {/* Download button */}
      {isCompleted && (
        <a
          href={getDownloadUrl(job.id)}
          download
          className="mt-3 inline-flex items-center gap-1.5 rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-emerald-500"
        >
          <svg
            className="h-3.5 w-3.5"
            fill="none"
            viewBox="0 0 24 24"
            strokeWidth={2}
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 16.5m0 0L7.5 12m4.5 4.5V3"
            />
          </svg>
          Download Video
        </a>
      )}
    </div>
  );
}
