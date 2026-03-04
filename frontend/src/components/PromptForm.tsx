"use client";

import { FormEvent, useState } from "react";

import { createJob } from "@/lib/api";

interface PromptFormProps {
  onJobCreated: () => void;
}

const RESOLUTIONS = ["360p", "480p", "720p", "1080p"] as const;

export function PromptForm({ onJobCreated }: PromptFormProps) {
  const [prompt, setPrompt] = useState("");
  const [duration, setDuration] = useState(5);
  const [resolution, setResolution] = useState<string>("360p");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!prompt.trim() || submitting) return;

    setSubmitting(true);
    setError(null);

    try {
      await createJob({ prompt: prompt.trim(), duration, resolution });
      setPrompt("");
      setDuration(5);
      setResolution("360p");
      onJobCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to create job");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      {/* Prompt textarea */}
      <div>
        <label htmlFor="prompt" className="block text-sm font-medium text-zinc-300">
          Prompt
        </label>
        <textarea
          id="prompt"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="Describe the video you want to generate..."
          maxLength={2000}
          rows={3}
          required
          className="mt-1 w-full resize-none rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-zinc-100 placeholder-zinc-500 outline-none transition-colors focus:border-zinc-500 focus:ring-1 focus:ring-zinc-500"
        />
        <p className="mt-1 text-right text-xs text-zinc-600">
          {prompt.length}/2000
        </p>
      </div>

      {/* Duration + Resolution row */}
      <div className="flex gap-4">
        <div className="flex-1">
          <label htmlFor="duration" className="block text-sm font-medium text-zinc-300">
            Duration (seconds)
          </label>
          <input
            id="duration"
            type="number"
            min={1}
            max={30}
            value={duration}
            onChange={(e) => setDuration(Number(e.target.value))}
            className="mt-1 w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-zinc-100 outline-none transition-colors focus:border-zinc-500 focus:ring-1 focus:ring-zinc-500"
          />
        </div>

        <div className="flex-1">
          <label htmlFor="resolution" className="block text-sm font-medium text-zinc-300">
            Resolution
          </label>
          <select
            id="resolution"
            value={resolution}
            onChange={(e) => setResolution(e.target.value)}
            className="mt-1 w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-zinc-100 outline-none transition-colors focus:border-zinc-500 focus:ring-1 focus:ring-zinc-500"
          >
            {RESOLUTIONS.map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Error */}
      {error && (
        <p className="rounded bg-red-950/50 px-3 py-2 text-xs text-red-400">
          {error}
        </p>
      )}

      {/* Submit */}
      <button
        type="submit"
        disabled={submitting || !prompt.trim()}
        className="w-full rounded-lg bg-zinc-100 px-4 py-2.5 text-sm font-semibold text-zinc-900 transition-colors hover:bg-white disabled:cursor-not-allowed disabled:opacity-40"
      >
        {submitting ? "Creating Job..." : "Generate Video"}
      </button>
    </form>
  );
}
