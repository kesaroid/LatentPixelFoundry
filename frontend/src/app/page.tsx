"use client";

import { JobList } from "@/components/JobList";
import { PromptForm } from "@/components/PromptForm";
import { useJobs } from "@/hooks/useJobs";

export default function Home() {
  const { jobs, loading, error, refetch } = useJobs();

  return (
    <div className="mx-auto max-w-2xl px-4 py-12">
      {/* Header */}
      <header className="mb-8">
        <h1 className="text-2xl font-bold tracking-tight text-zinc-100">
          Video Generator
        </h1>
        <p className="mt-1 text-sm text-zinc-500">
          Enter a prompt to generate an AI video.
        </p>
      </header>

      {/* Prompt Form */}
      <section className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-5">
        <PromptForm onJobCreated={refetch} />
      </section>

      {/* Job List */}
      <section className="mt-8">
        <h2 className="mb-4 text-lg font-semibold text-zinc-200">Jobs</h2>
        <JobList jobs={jobs} loading={loading} error={error} />
      </section>
    </div>
  );
}
