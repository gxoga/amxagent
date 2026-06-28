#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The amxagent authors
"""All-core AMX LLM throughput benchmark for the SGLang CPU backend.

Drives concurrent chat-completion requests straight at the inference server
(default http://localhost:8000 — the raw SGLang endpoint, not the proxy) and
reports TTFT, per-request prefill/decode token rates, and the aggregate decode
throughput that the AMX kernels sustain across all cores. Optionally samples
per-core CPU utilization (needs psutil) to show every core is engaged.

The backend itself is what uses AMX on all cores (SGLang CPU: TP across NUMA +
OpenMP threads, BF16 TDPBF16PS matmul, INT8 MoE). This client just applies enough
concurrent load to saturate it and measures the result.

Usage:
    python llm_amx_benchmark.py --concurrency 8 --input-tokens 512 --output-tokens 256
"""
import argparse
import asyncio
import json
import statistics
import threading
import time

import httpx

FILLER = "The quick brown fox jumps over the lazy dog. "


def make_prompt(approx_tokens: int) -> str:
    # ~4 characters per token is a good enough heuristic for load generation;
    # the exact prompt length is read back from the server's usage report.
    target_chars = max(1, approx_tokens * 4)
    body = (FILLER * (target_chars // len(FILLER) + 1))[:target_chars]
    return "Summarize the following text in detail:\n" + body


async def fetch_model_id(client: httpx.AsyncClient, backend: str, headers: dict) -> str:
    r = await client.get(f"{backend}/v1/models", headers=headers, timeout=30.0)
    r.raise_for_status()
    return r.json()["data"][0]["id"]


async def one_request(client, url, model, prompt, max_tokens, headers):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    t0 = time.perf_counter()
    ttft = None
    completion_tokens = 0
    prompt_tokens = None
    async with client.stream("POST", url, json=payload, headers=headers, timeout=600.0) as resp:
        resp.raise_for_status()
        async for line in resp.aiter_lines():
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                continue
            choices = chunk.get("choices") or []
            if choices and choices[0].get("delta", {}).get("content"):
                if ttft is None:
                    ttft = time.perf_counter() - t0
                completion_tokens += 1  # fallback; overwritten by usage if present
            usage = chunk.get("usage")
            if usage:
                prompt_tokens = usage.get("prompt_tokens", prompt_tokens)
                completion_tokens = usage.get("completion_tokens", completion_tokens)
    total = time.perf_counter() - t0
    if ttft is None:
        ttft = total
    return {"ttft": ttft, "total": total,
            "prompt_tokens": prompt_tokens or 0, "completion_tokens": completion_tokens}


class CpuSampler:
    """Background per-core CPU% sampler (no-op if psutil is unavailable)."""
    def __init__(self, interval=0.5):
        self.interval = interval
        self._stop = threading.Event()
        self._samples = []
        try:
            import psutil  # noqa: F401
            self._psutil = psutil
        except Exception:
            self._psutil = None
        self._thread = None

    def __enter__(self):
        if self._psutil:
            self._psutil.cpu_percent(percpu=True)  # prime
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
        return self

    def _run(self):
        while not self._stop.wait(self.interval):
            self._samples.append(self._psutil.cpu_percent(percpu=True))

    def __exit__(self, *a):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)

    def summary(self):
        if not self._samples:
            return None
        ncpu = len(self._samples[0])
        per_core_mean = [statistics.mean(s[i] for s in self._samples) for i in range(ncpu)]
        busy = sum(1 for m in per_core_mean if m > 50.0)
        return {"ncpu": ncpu, "overall_mean": statistics.mean(per_core_mean), "busy_gt50": busy}


async def run_level(args, headers):
    prompt = make_prompt(args.input_tokens)
    url = f"{args.backend}/v1/chat/completions"
    limits = httpx.Limits(max_connections=args.concurrency + 4)
    async with httpx.AsyncClient(limits=limits) as client:
        model = args.model or await fetch_model_id(client, args.backend, headers)
        # warmup (not measured)
        try:
            await one_request(client, url, model, make_prompt(8), 8, headers)
        except Exception:
            pass

        sem = asyncio.Semaphore(args.concurrency)
        results = []

        async def worker():
            async with sem:
                results.append(await one_request(client, url, model, prompt, args.output_tokens, headers))

        with CpuSampler() as sampler:
            wall0 = time.perf_counter()
            await asyncio.gather(*(worker() for _ in range(args.num_requests)))
            wall = time.perf_counter() - wall0
        return model, results, wall, sampler.summary()


def report(args, model, results, wall, cpu):
    ttfts = [r["ttft"] for r in results]
    decode_rates = [r["completion_tokens"] / (r["total"] - r["ttft"])
                    for r in results if r["total"] - r["ttft"] > 1e-6 and r["completion_tokens"]]
    prefill_rates = [r["prompt_tokens"] / r["ttft"] for r in results if r["ttft"] > 1e-6 and r["prompt_tokens"]]
    out_tokens = sum(r["completion_tokens"] for r in results)
    agg = out_tokens / wall if wall > 0 else 0.0

    def pct(xs, p):
        return statistics.quantiles(xs, n=100)[p - 1] if len(xs) >= 2 else (xs[0] if xs else 0.0)

    print(f"  model            : {model}")
    print(f"  requests         : {len(results)}  (concurrency {args.concurrency})")
    print(f"  in/out tokens    : ~{args.input_tokens} / {args.output_tokens}  "
          f"(measured prompt≈{int(statistics.mean([r['prompt_tokens'] for r in results] or [0]))})")
    print(f"  TTFT             : mean {statistics.mean(ttfts):.2f}s  p50 {pct(ttfts,50):.2f}s  p99 {pct(ttfts,99):.2f}s")
    if prefill_rates:
        print(f"  prefill / req    : {statistics.mean(prefill_rates):.1f} tok/s")
    if decode_rates:
        print(f"  decode / req     : {statistics.mean(decode_rates):.1f} tok/s")
    print(f"  AGGREGATE decode : {agg:.1f} tok/s  ({out_tokens} tokens / {wall:.1f}s wall)")
    if cpu:
        print(f"  CPU util         : {cpu['overall_mean']:.0f}% mean, "
              f"{cpu['busy_gt50']}/{cpu['ncpu']} cores >50% busy")
    else:
        print("  CPU util         : (install psutil to sample per-core usage)")


async def main_async():
    ap = argparse.ArgumentParser(description="All-core AMX LLM throughput benchmark")
    ap.add_argument("--backend", default="http://localhost:8000",
                    help="raw SGLang OpenAI endpoint (default %(default)s)")
    ap.add_argument("--model", default="", help="model id (default: auto from /v1/models)")
    ap.add_argument("--input-tokens", type=int, default=512)
    ap.add_argument("--output-tokens", type=int, default=256)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--num-requests", type=int, default=8)
    ap.add_argument("--api-key", default="", help="bearer token (only if the backend enforces one)")
    args = ap.parse_args()

    headers = {"Content-Type": "application/json"}
    if args.api_key:
        headers["Authorization"] = f"Bearer {args.api_key}"

    model, results, wall, cpu = await run_level(args, headers)
    report(args, model, results, wall, cpu)


if __name__ == "__main__":
    asyncio.run(main_async())
