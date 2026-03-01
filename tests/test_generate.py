#!/usr/bin/env python3
"""
End-to-end GPU worker test with a dummy prompt.

Starts a mock backend to receive status callbacks and the video upload,
then sends a generate request to the worker and waits for the full
pipeline to complete.

Model layout (worker expects /models via -v ~/models:/models):
    /models/
      ltx-2-19b-dev.safetensors (or ltx-2-19b-dev-fp8.safetensors)
      ltx-2-19b-distilled-lora-384.safetensors
      ltx-2-spatial-upsampler-x2-1.0.safetensors
      gemma-3/                    <- LTX-2 layout (NOT flat google/gemma-3-1b-it)
        tokenizer/                 (preprocessor_config.json, tokenizer.json, etc.)
        text_encoder/             (config.json, model-*.safetensors, etc.)
    Run scripts/download_gemma3.sh to get the correct Gemma-3 layout.

Usage (on the EC2 instance):
    # 1. Make sure the worker container is running with BACKEND_URL
    #    pointing to this machine's mock server:
    #
    #    docker stop lpf-worker 2>/dev/null; docker rm lpf-worker 2>/dev/null
    #    docker run -d --name lpf-worker --gpus all --restart unless-stopped \
    #        -p 9000:9000 -v ~/models:/models \
    #        -e BACKEND_URL=http://172.17.0.1:8000 \
    #        -e WORKER_API_KEY=test-key \
    #        lpf-worker
    #
    #    (172.17.0.1 is the default Docker bridge gateway, reachable from containers)
    #
    # 2. Run the test:
    #    pip install httpx uvicorn fastapi python-multipart
    #    python test_generate.py
    #
    # Options:
    #    --worker-url http://localhost:9000   Worker address (default)
    #    --mock-port 8000                     Mock backend port (default)
    #    --prompt "your prompt"               Custom prompt
    #    --duration 2                         Duration in seconds (default: 2)
    #    --resolution 360p                    Resolution (default: 360p)
    #    --timeout 600                        Max wait in seconds (default: 600)
    #    --api-key test-key                   Worker API key (default: test-key)
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Optional

import httpx
import uvicorn
from fastapi import FastAPI, File, Request, UploadFile
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# State shared between mock server and test driver
# ---------------------------------------------------------------------------

test_state = {
    "status_updates": [],
    "video_received": False,
    "video_size_bytes": 0,
    "video_path": None,
    "done_event": None,  # set in main()
    "error": None,
}


# ---------------------------------------------------------------------------
# Mock backend (receives callbacks from the worker)
# ---------------------------------------------------------------------------

mock_app = FastAPI(title="Mock Backend for Worker Test")


@mock_app.patch("/api/jobs/{job_id}/status")
async def mock_status_update(job_id: str, request: Request):
    body = await request.json()
    status = body.get("status", "UNKNOWN")
    error_msg = body.get("error_message")
    gen_time = body.get("generation_time_seconds")

    entry = {"status": status, "timestamp": time.time()}
    if error_msg:
        entry["error_message"] = error_msg
    if gen_time is not None:
        entry["generation_time_seconds"] = gen_time

    test_state["status_updates"].append(entry)

    label = f"  -> Status: {status}"
    if gen_time is not None:
        label += f" (generation took {gen_time:.1f}s)"
    if error_msg:
        label += f" — ERROR: {error_msg[:200]}"
    print(label)

    if status in ("FAILED",):
        test_state["error"] = error_msg
        test_state["done_event"].set()

    return {"ok": True}


@mock_app.post("/api/jobs/{job_id}/upload")
async def mock_upload(job_id: str, file: UploadFile = File(...)):
    save_dir = Path("test_outputs")
    save_dir.mkdir(exist_ok=True)
    save_path = save_dir / f"{job_id}.mp4"

    size = 0
    with open(save_path, "wb") as f:
        while chunk := await file.read(1024 * 1024):
            f.write(chunk)
            size += len(chunk)

    test_state["video_received"] = True
    test_state["video_size_bytes"] = size
    test_state["video_path"] = str(save_path)

    print(f"  -> Video uploaded: {size / (1024*1024):.1f} MB -> {save_path}")
    test_state["done_event"].set()

    return {"status": "ok", "video_path": str(save_path)}


# ---------------------------------------------------------------------------
# Test driver
# ---------------------------------------------------------------------------


async def run_test(args: argparse.Namespace) -> bool:
    """Run the full test sequence. Returns True on success."""
    job_id = str(uuid.uuid4())
    worker_url = args.worker_url.rstrip("/")

    print("=" * 60)
    print("GPU Worker End-to-End Test")
    print("=" * 60)
    print(f"  Worker URL:  {worker_url}")
    print(f"  Mock port:   {args.mock_port}")
    print(f"  Job ID:      {job_id}")
    print(f"  Prompt:      {args.prompt!r}")
    print(f"  Duration:    {args.duration}s")
    print(f"  Resolution:  {args.resolution}")
    print(f"  Timeout:     {args.timeout}s")
    print("=" * 60)

    # Step 1: Health check
    print("\n[1/3] Health check...")
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{worker_url}/health")
        if resp.status_code == 200:
            print(f"  -> Worker is healthy: {resp.json()}")
        else:
            print(f"  -> Unexpected status {resp.status_code}: {resp.text}")
            return False
    except Exception as exc:
        print(f"  -> Cannot reach worker at {worker_url}: {exc}")
        return False

    # Step 2: Send generate request
    print(f"\n[2/3] Sending generate request...")
    payload = {
        "job_id": job_id,
        "prompt": args.prompt,
        "duration": args.duration,
        "resolution": args.resolution,
        "backend_url": f"http://172.17.0.1:{args.mock_port}",
        "upload_url": f"http://172.17.0.1:{args.mock_port}/api/jobs/{job_id}/upload",
        "status_url": f"http://172.17.0.1:{args.mock_port}/api/jobs/{job_id}/status",
    }

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                f"{worker_url}/generate",
                json=payload,
                headers={"X-Worker-API-Key": args.api_key},
            )
        if resp.status_code == 202:
            print(f"  -> Accepted: {resp.json()}")
        else:
            print(f"  -> Unexpected status {resp.status_code}: {resp.text}")
            return False
    except Exception as exc:
        print(f"  -> Failed to send generate request: {exc}")
        return False

    # Step 3: Wait for completion
    print(f"\n[3/3] Waiting for worker to finish (timeout {args.timeout}s)...")
    start = time.monotonic()
    try:
        await asyncio.wait_for(test_state["done_event"].wait(), timeout=args.timeout)
    except asyncio.TimeoutError:
        elapsed = time.monotonic() - start
        print(f"\n  TIMEOUT after {elapsed:.0f}s — worker did not complete.")
        print(f"  Status updates received: {len(test_state['status_updates'])}")
        for u in test_state["status_updates"]:
            print(f"    - {u['status']}")
        return False

    elapsed = time.monotonic() - start

    # Report results
    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)
    print(f"  Total time:       {elapsed:.1f}s")
    print(f"  Status updates:   {len(test_state['status_updates'])}")
    for u in test_state["status_updates"]:
        line = f"    - {u['status']}"
        if "generation_time_seconds" in u:
            line += f" (gen: {u['generation_time_seconds']:.1f}s)"
        if "error_message" in u:
            line += f" — {u['error_message'][:100]}"
        print(line)

    if test_state["error"]:
        print(f"\n  FAILED: {test_state['error'][:300]}")
        return False

    if test_state["video_received"]:
        mb = test_state["video_size_bytes"] / (1024 * 1024)
        print(f"  Video received:   {mb:.1f} MB")
        print(f"  Saved to:         {test_state['video_path']}")
        print("\n  SUCCESS")
        return True
    else:
        print("\n  FAILED: No video received")
        return False


async def main():
    parser = argparse.ArgumentParser(description="Test the GPU worker with a dummy prompt")
    parser.add_argument("--worker-url", default="http://localhost:9000", help="Worker base URL")
    parser.add_argument("--mock-port", type=int, default=8000, help="Port for mock backend")
    parser.add_argument(
        "--prompt",
        default="A slow cinematic shot of a golden retriever running through a sunlit meadow, soft bokeh background, 4K quality",
        help="Generation prompt",
    )
    parser.add_argument("--duration", type=int, default=2, help="Video duration in seconds")
    parser.add_argument("--resolution", default="360p", help="Resolution (360p, 480p, 720p, 1080p)")
    parser.add_argument("--timeout", type=int, default=600, help="Max wait seconds")
    parser.add_argument("--api-key", default="test-key", help="Worker API key")
    args = parser.parse_args()

    test_state["done_event"] = asyncio.Event()

    # Start mock backend in background
    config = uvicorn.Config(
        mock_app,
        host="0.0.0.0",
        port=args.mock_port,
        log_level="warning",
    )
    server = uvicorn.Server(config)
    server_task = asyncio.create_task(server.serve())

    # Give the server a moment to start
    await asyncio.sleep(0.5)

    try:
        success = await run_test(args)
    finally:
        server.should_exit = True
        await server_task

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    asyncio.run(main())
