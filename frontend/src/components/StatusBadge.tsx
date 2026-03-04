import { JobStatus } from "@/lib/types";

const STATUS_CONFIG: Record<JobStatus, { label: string; classes: string }> = {
  [JobStatus.PENDING]: {
    label: "Pending",
    classes: "bg-zinc-700/50 text-zinc-300",
  },
  [JobStatus.TRIGGERED]: {
    label: "Triggered",
    classes: "bg-blue-900/50 text-blue-300",
  },
  [JobStatus.GENERATING]: {
    label: "Generating",
    classes: "bg-amber-900/50 text-amber-300 animate-pulse",
  },
  [JobStatus.UPLOADING]: {
    label: "Uploading",
    classes: "bg-indigo-900/50 text-indigo-300",
  },
  [JobStatus.COMPLETED]: {
    label: "Completed",
    classes: "bg-emerald-900/50 text-emerald-300",
  },
  [JobStatus.FAILED]: {
    label: "Failed",
    classes: "bg-red-900/50 text-red-300",
  },
};

interface StatusBadgeProps {
  status: JobStatus;
}

export function StatusBadge({ status }: StatusBadgeProps) {
  const config = STATUS_CONFIG[status];
  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${config.classes}`}
    >
      {config.label}
    </span>
  );
}
