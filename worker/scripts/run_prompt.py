#!/usr/bin/env python3
"""
Run LTX-2 text-to-video for a single prompt. Saves an MP4 to the given output path.

Use this to test the pipeline on the EC2 instance (or inside the worker container).

  Inside the worker container (torch/diffusers are installed there; /models is mounted):
    docker exec -it lpf-worker python3 /app/scripts/run_prompt.py --prompt "A cat walking in the rain" --duration 5 --output /tmp/test.mp4

  On instance host you would need a venv with worker deps; prefer running in container as above.
"""
from __future__ import annotations

import argparse
import os
import sys

# Add worker dir (parent of scripts/) so pipeline_ltx2 is importable
_script_dir = os.path.dirname(os.path.abspath(__file__))
_worker_dir = os.path.realpath(os.path.join(_script_dir, ".."))
if _worker_dir not in sys.path:
    sys.path.insert(0, _worker_dir)

# Ensure pipeline_ltx2.py exists (sync with deploy-worker.sh build if missing)
if not os.path.isfile(os.path.join(_worker_dir, "pipeline_ltx2.py")):
    print(f"[run_prompt] Error: pipeline_ltx2.py not found in {_worker_dir}", file=sys.stderr)
    print("Run from your Mac: ./deploy-worker.sh build", file=sys.stderr)
    sys.exit(1)

# Optional: when running on host, point to ~/models if /models does not exist
if not os.path.isdir("/models") and os.path.isdir(os.path.expanduser("~/models")):
    os.environ.setdefault("MODELS_DIR", os.path.expanduser("~/models"))

from pipeline_ltx2 import run as run_ltx2


def main() -> None:
    p = argparse.ArgumentParser(description="Run LTX-2 text-to-video for a prompt.")
    p.add_argument("--prompt", "-p", required=True, help="Text prompt for video generation")
    p.add_argument("--duration", "-d", type=float, default=5.0, help="Duration in seconds (default: 5)")
    p.add_argument("--resolution", "-r", default="720p", choices=["480p", "720p", "1080p"], help="Resolution (default: 720p)")
    p.add_argument("--output", "-o", default="output.mp4", help="Output MP4 path (default: output.mp4)")
    p.add_argument("--seed", "-s", type=int, default=None, help="Random seed for reproducibility")
    args = p.parse_args()

    print(f"[run_prompt] prompt={args.prompt!r} duration={args.duration}s resolution={args.resolution} output={args.output}")
    out = run_ltx2(
        args.prompt,
        duration_sec=args.duration,
        resolution=args.resolution,
        output_path=args.output,
        seed=args.seed,
    )
    print(f"[run_prompt] Saved: {out}")


if __name__ == "__main__":
    main()
