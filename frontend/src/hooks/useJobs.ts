"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { fetchJobs } from "@/lib/api";
import { Job } from "@/lib/types";

const POLL_INTERVAL_MS = 5_000;

interface UseJobsReturn {
  jobs: Job[];
  loading: boolean;
  error: string | null;
  refetch: () => Promise<void>;
}

/**
 * Polls GET /api/jobs every 5 seconds.
 * Returns current job list, loading/error state, and a manual refetch fn.
 */
export function useJobs(): UseJobsReturn {
  const [jobs, setJobs] = useState<Job[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const load = useCallback(async () => {
    try {
      const data = await fetchJobs();
      setJobs(data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to fetch jobs");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    // Initial fetch
    load();

    // Start polling
    intervalRef.current = setInterval(load, POLL_INTERVAL_MS);

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, [load]);

  return { jobs, loading, error, refetch: load };
}
