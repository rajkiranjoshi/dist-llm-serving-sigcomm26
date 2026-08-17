#!/usr/bin/env python3
"""Load driver + evidence table for one arm of the llm-d routing A/B.

Runs INSIDE the cluster (see drive.sh). That is not incidental: `kubectl
port-forward svc/...` resolves to a single pod and bypasses kube-proxy entirely,
so driving the baseline arm from the host would report 100% of traffic on one pod
as a pure measurement artifact.

Standard library only -- no pip install, nothing to version-pin.

Configured entirely by environment variables (see drive.sh):
  ARM             label for this run, e.g. "baseline" or "llmd"
  ENDPOINT        base URL to send traffic to, e.g. http://10.0.0.1:8000
  POD_ENDPOINTS   comma-separated pod IP:port list, scraped for /metrics
  MODEL           model name to request
  N_PREFIXES      number of distinct shared prefixes in the workload
  PREFIX_TOKENS   approximate tokens per prefix
  REQUESTS        total requests to send (after warmup)
  WARMUP          requests to send and discard before measuring
  CONCURRENCY     number of concurrent senders
  SEED            RNG seed, so both arms see an identical request sequence
  MAX_TOKENS      output tokens to request
"""
import json
import os
import random
import re
import sys
import threading
import time
import http.client
import urllib.request
from collections import defaultdict


def env(name, default=None, cast=str):
    v = os.environ.get(name, default)
    if v is None:
        sys.exit("missing required env var %s" % name)
    return cast(v)


ARM = env("ARM")
ENDPOINT = env("ENDPOINT")
POD_ENDPOINTS = [p for p in env("POD_ENDPOINTS", "").split(",") if p]
MODEL = env("MODEL", "Qwen/Qwen3-32B")
N_PREFIXES = env("N_PREFIXES", "16", int)
PREFIX_TOKENS = env("PREFIX_TOKENS", "1500", int)
REQUESTS = env("REQUESTS", "400", int)
WARMUP = env("WARMUP", "40", int)
CONCURRENCY = env("CONCURRENCY", "16", int)
SEED = env("SEED", "1234", int)
MAX_TOKENS = env("MAX_TOKENS", "8", int)

HOST, _, PORT = ENDPOINT.replace("http://", "").partition(":")
PORT = int(PORT or 80)

# Each arm gets its own prefix salt so its prefixes are genuinely unseen and the
# arm starts cold even without a pod restart. drive.sh ALSO restarts the pods
# between arms; this makes the result independent of that working.
PREFIXES = [
    " ".join("%s_p%02d_w%d" % (ARM, i, w) for w in range(PREFIX_TOKENS))
    for i in range(N_PREFIXES)
]


def scrape(pod_endpoint):
    """Pull the handful of vLLM-compatible counters we report on."""
    wanted = ("vllm:prefix_cache_hits", "vllm:prefix_cache_queries",
              "vllm:request_success_total", "vllm:num_requests_running",
              "vllm:num_requests_waiting")
    out = dict.fromkeys((w.replace("vllm:", "") for w in wanted), 0.0)
    try:
        with urllib.request.urlopen("http://%s/metrics" % pod_endpoint,
                                    timeout=10) as r:
            txt = r.read().decode()
    except Exception as e:                        # a pod restarting mid-run
        print("  warn: could not scrape %s: %s" % (pod_endpoint, e))
        return out
    for w in wanted:
        m = re.search(r'^%s(?:\{[^}]*\})?\s+([0-9.eE+-]+)$' % re.escape(w),
                      txt, re.M)
        if m:
            out[w.replace("vllm:", "")] = float(m.group(1))
    return out


def send(prompt, prefix_idx):
    """One streaming completion. Returns a result dict.

    A fresh connection per request, deliberately. A single keep-alive connection
    to a ClusterIP pins to one backend for its lifetime, so reusing connections
    would measure connection balancing rather than request balancing -- and would
    flatter the L4 baseline into looking like it does nothing at all.
    """
    conn = http.client.HTTPConnection(HOST, PORT, timeout=120)
    body = json.dumps({"model": MODEL, "prompt": prompt,
                       "max_tokens": MAX_TOKENS, "stream": True,
                       "stream_options": {"include_usage": True}})
    t0 = time.perf_counter()
    ttft = None
    pod = "?"
    cached = ptok = None
    try:
        conn.request("POST", "/v1/completions", body,
                     {"Content-Type": "application/json"})
        r = conn.getresponse()
        # Envoy lowercases headers, the pod returns X-Inference-Pod. Match either.
        for k, v in r.getheaders():
            if k.lower() == "x-inference-pod":
                pod = v
        while True:
            # r.readline(), not r.fp.readline(): the latter skips http.client's
            # chunked-transfer decoding and blocks on the chunk framing.
            line = r.readline()
            if not line:
                break
            if not line.startswith(b"data:"):
                continue
            if ttft is None:
                ttft = (time.perf_counter() - t0) * 1000
            chunk = line[5:].strip()
            if chunk == b"[DONE]":
                continue
            try:
                usage = json.loads(chunk).get("usage") or {}
            except ValueError:
                continue
            if usage:
                ptok = usage.get("prompt_tokens", ptok)
                detail = usage.get("prompt_tokens_detail") or {}
                if detail.get("cached_tokens") is not None:
                    cached = detail["cached_tokens"]
    finally:
        conn.close()
    return {"ttft": ttft, "total": (time.perf_counter() - t0) * 1000,
            "pod": pod, "cached": cached, "ptok": ptok, "prefix": prefix_idx}


def pct(vals, q):
    if not vals:
        return float("nan")
    s = sorted(vals)
    return s[min(len(s) - 1, int(round(q / 100.0 * (len(s) - 1))))]


def run(total, label):
    """Drive `total` requests at CONCURRENCY. Returns list of result tuples."""
    rng = random.Random(SEED if label == "measure" else SEED + 1)
    plan = [rng.randrange(N_PREFIXES) for _ in range(total)]
    results = []
    lock = threading.Lock()
    nxt = [0]

    def worker(wid):
        while True:
            with lock:
                i = nxt[0]
                if i >= total:
                    return
                nxt[0] = i + 1
            idx = plan[i]
            prompt = "%s question_%d_%d" % (PREFIXES[idx], i, wid)
            try:
                res = send(prompt, idx)
            except Exception as e:
                res = {"ttft": None, "total": None, "prefix": idx,
                       "pod": "ERROR:%s" % type(e).__name__,
                       "cached": None, "ptok": None}
            with lock:
                results.append(res)

    threads = [threading.Thread(target=worker, args=(w,))
               for w in range(CONCURRENCY)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results, time.perf_counter() - t0


print("=" * 78)
print("ARM: %-12s endpoint=%s" % (ARM, ENDPOINT))
print("workload: %d prefixes x ~%d tok, %d requests @ concurrency %d "
      "(+%d discarded warmup), seed=%d"
      % (N_PREFIXES, PREFIX_TOKENS, REQUESTS, CONCURRENCY, WARMUP, SEED))
print("=" * 78)

if WARMUP:
    run(WARMUP, "warmup")
    print("warmup: %d requests sent and discarded" % WARMUP)

before = {p: scrape(p) for p in POD_ENDPOINTS}
results, wall = run(REQUESTS, "measure")
after = {p: scrape(p) for p in POD_ENDPOINTS}

ok = [r for r in results if r["ttft"] is not None]
errs = [r for r in results if r["ttft"] is None]

by_pod = defaultdict(list)
for r in ok:
    by_pod[r["pod"]].append(r)

print()
print("--- per-pod request distribution and client-measured TTFT ---")
print("%-32s %6s %7s %10s %10s %10s"
      % ("pod", "reqs", "share", "ttft_p50", "ttft_p90", "cached%"))
for pod in sorted(by_pod):
    rs = by_pod[pod]
    ttfts = [x["ttft"] for x in rs]
    cs = [x["cached"] for x in rs if x["cached"] is not None]
    ps = [x["ptok"] for x in rs if x["ptok"] is not None]
    cachedpct = (100.0 * sum(cs) / sum(ps)) if cs and sum(ps) else float("nan")
    print("%-32s %6d %6.1f%% %9.1fms %9.1fms %9.1f%%"
          % (pod, len(rs), 100.0 * len(rs) / len(ok),
             pct(ttfts, 50), pct(ttfts, 90), cachedpct))

all_ttft = [x["ttft"] for x in ok]
all_c = [x["cached"] for x in ok if x["cached"] is not None]
all_p = [x["ptok"] for x in ok if x["ptok"] is not None]
agg_cached = (100.0 * sum(all_c) / sum(all_p)) if all_c and sum(all_p) else float("nan")

# THE metric that distinguishes the two arms. Both spread requests evenly across
# pods, so the distribution table alone looks identical. What differs is WHICH pod
# gets WHICH prefix: L7 routing concentrates each prefix onto few pods (so it stays
# cached), L4 sprays every prefix across all of them (so nothing stays cached).
prefix_pods = defaultdict(lambda: defaultdict(int))
for r in ok:
    prefix_pods[r["prefix"]][r["pod"]] += 1
concentrations, distinct_counts = [], []
for idx, pods in prefix_pods.items():
    total = sum(pods.values())
    concentrations.append(max(pods.values()) / float(total))
    distinct_counts.append(len(pods))
mean_conc = 100.0 * sum(concentrations) / len(concentrations) if concentrations else float("nan")
mean_distinct = sum(distinct_counts) / float(len(distinct_counts)) if distinct_counts else float("nan")

print()
print("--- prefix -> pod affinity (the thing the distribution table hides) ---")
print("  distinct pods serving each prefix : %.2f of %d  (1.0 = perfect partition)"
      % (mean_distinct, len(POD_ENDPOINTS)))
print("  mean concentration on top pod     : %.1f%%  (100%% = every request for a"
      " prefix went to one pod)" % mean_conc)
print("  per-prefix breakdown:")
for idx in sorted(prefix_pods):
    pods = prefix_pods[idx]
    total = sum(pods.values())
    bars = " ".join("%s:%d" % (p.split("-")[-1], n)
                    for p, n in sorted(pods.items(), key=lambda kv: -kv[1]))
    print("    prefix %2d (%3d reqs, top=%3.0f%%): %s"
          % (idx, total, 100.0 * max(pods.values()) / total, bars))

print()
print("--- per-pod simulated prefix cache, from /metrics deltas ---")
print("%-32s %14s %14s %9s" % ("pod endpoint", "hit_tokens", "query_tokens",
                               "hit_rate"))
tot_h = tot_q = 0.0
for p in POD_ENDPOINTS:
    h = after[p]["prefix_cache_hits"] - before[p]["prefix_cache_hits"]
    q = after[p]["prefix_cache_queries"] - before[p]["prefix_cache_queries"]
    tot_h += h
    tot_q += q
    print("%-32s %14.0f %14.0f %8.1f%%"
          % (p, h, q, 100.0 * h / q if q else float("nan")))
print("%-32s %14.0f %14.0f %8.1f%%"
      % ("TOTAL", tot_h, tot_q, 100.0 * tot_h / tot_q if tot_q else float("nan")))

print()
print("--- aggregate ---")
print("  requests ok/err        : %d / %d" % (len(ok), len(errs)))
print("  wall time              : %.1f s  (%.1f req/s)" % (wall, len(ok) / wall))
print("  TTFT p50 / p90 / p99   : %.1f / %.1f / %.1f ms"
      % (pct(all_ttft, 50), pct(all_ttft, 90), pct(all_ttft, 99)))
print("  cached prompt tokens   : %.1f%%" % agg_cached)
print("  pods receiving traffic : %d of %d"
      % (len([p for p in by_pod if not p.startswith("ERROR")]),
         len(POD_ENDPOINTS)))
print("  prefix->pod partition  : %.2f pods/prefix, %.1f%% top-pod concentration"
      % (mean_distinct, mean_conc))
if errs:
    kinds = defaultdict(int)
    for e in errs:
        kinds[e["pod"]] += 1
    print("  errors                 : %s" % dict(kinds))

summary = {
    "arm": ARM, "endpoint": ENDPOINT, "ok": len(ok), "err": len(errs),
    "wall_s": round(wall, 2), "rps": round(len(ok) / wall, 2),
    "ttft_p50": round(pct(all_ttft, 50), 1),
    "ttft_p90": round(pct(all_ttft, 90), 1),
    "ttft_p99": round(pct(all_ttft, 99), 1),
    "cached_pct": round(agg_cached, 1),
    "metrics_hit_rate_pct": round(100.0 * tot_h / tot_q, 1) if tot_q else None,
    "pods_per_prefix": round(mean_distinct, 2),
    "top_pod_concentration_pct": round(mean_conc, 1),
    "distribution": {p: len(rs) for p, rs in sorted(by_pod.items())},
}
print()
print("JSON_SUMMARY:" + json.dumps(summary))
