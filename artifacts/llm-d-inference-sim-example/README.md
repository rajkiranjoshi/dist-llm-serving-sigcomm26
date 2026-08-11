# Deploying llm-d on minikube with llm-d-inference-sim

A GPU-free, laptop-scale deployment of the llm-d
[`optimized-baseline`](https://github.com/llm-d/llm-d/tree/main/guides/optimized-baseline)
routing stack, backed by [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim)
instead of real model servers — plus an A/B experiment that measures what the
router actually buys you against a plain Kubernetes Service.

Everything here has been run end to end on a **2 vCPU / 7 GB Ubuntu VM** and on
**Apple Silicon**. No accelerator, no HuggingFace token, no model download.

- Deploy, with images already cached: **~8 s**
- Deploy, cold: a few minutes, dominated by minikube's own ~483 MB base image;
  this example's four images add ~290 MB
- The A/B experiment: **~1 min 50 s** for both arms
- Total host disk: **~5 GB** including minikube itself

---

## What you will see

Same four simulator pods. Same workload. Same seed. The only thing that differs is
the routing layer. One representative run on a 2 vCPU / 7 GB Ubuntu 22.04 VM
(x86_64, `--driver=docker --cpus=2 --memory=4g`):

| metric | baseline (plain Service, L4) | llm-d (Envoy + EPP, L7) | delta |
| --- | --- | --- | --- |
| distinct pods serving each prefix | 4.00 of 4 | **1.00 of 4** | 4.00× |
| top-pod concentration | 36.2% | **100.0%** | 2.76× |
| prefix cache hit rate | 28.8% | **98.9%** | 3.43× |
| TTFT p50 | 1009.8 ms | **119.7 ms** | 8.44× |
| TTFT p90 | 2010.3 ms | **277.0 ms** | 7.26× |
| TTFT p99 | 2698.5 ms | **434.0 ms** | 6.22× |
| throughput | 7.49 req/s | **34.91 req/s** | 4.66× |
| request share per pod | 23 / 26 / 26 / 25 % | 24 / 26 / 27 / 23 % | — |

Read the first and last rows of that table together, because they are the whole
point:

**Both arms spread requests evenly across the four pods** (last row). If you only
looked at request counts — which is what most load-balancer dashboards show you —
you would conclude the router is doing nothing. But the L4 arm sends *every* prefix
to *all four* pods, while the L7 arm sends *each* prefix to *exactly one* pod (first
row). Same load distribution, completely different cache behaviour.

That is the distinction worth taking away: an L4 load balancer distributes
*connections*; a content-aware L7 router distributes *work* — and can partition a
keyspace while still balancing load.

### How much of this is reproducible

**Expect your absolute numbers to differ.** On a 2-vCPU host the driver competes with
the simulator pods for CPU, so latency figures move run to run. Across two
back-to-back runs the baseline TTFT p50 measured 1009.8 ms and 1514.7 ms, and the
baseline hit rate 28.8% and 24.9%.

What was **stable** across runs is everything structural — and that is what the
experiment is actually claiming:

| | Linux run 1 | Linux run 2 | macOS (arm64) |
| --- | --- | --- | --- |
| pods per prefix, baseline → llm-d | 4.00 → 1.00 | 4.00 → 1.00 | 4.00 → 1.00 |
| top-pod concentration, baseline → llm-d | 36.2% → 100.0% | 35.9% → 100.0% | 35.0% → 100.0% |
| llm-d hit rate | 98.9% | 98.9% | 98.3% |
| TTFT p50 improvement | 8.44× | 6.79× | 6.90× |
| throughput improvement | 4.66× | 4.82× | 4.43× |

Treat the ratios as "roughly 4–8× TTFT and ~4.5× throughput", not as constants. The
partition result — **4.00 → 1.00 pods per prefix, 100% top-pod concentration** —
reproduced exactly in all three runs, across two platforms and two CPU
architectures. That is the claim to hold this artifact to.

---

## Why this works without a GPU

`optimized-baseline` configures four EPP plugins:

```yaml
plugins:
- type: approx-prefix-cache-producer
- type: inflight-load-producer
- type: prefix-cache-affinity-filter
- type: token-load-scorer
```

All four compute **inside the router**:

| plugin | where its data comes from |
| --- | --- |
| `approx-prefix-cache-producer` | hashes request bodies in EPP; maintains its own approximate model of what each endpoint has cached |
| `inflight-load-producer` | counts in-flight requests/tokens from EPP's own request-lifecycle hooks, discounting the cached prefix portion |
| `prefix-cache-affinity-filter` | reads `PrefixCacheMatchInfo` + `InFlightLoad` endpoint attributes, both produced above |
| `token-load-scorer` | reads `InFlightLoad` |

**None of them scrapes the model server.** So the routing logic under test is the
real, unmodified guide configuration — nothing is stubbed or mocked. The only thing
simulated is the model server's *response timing*, which is exactly what
`llm-d-inference-sim` is for.

And the simulator's timing model is rich enough for the routing decisions to have
consequences. With `--latency-calculator=per-token`:

```
prefill_time = prefill-overhead + (n − n_cached) × prefill-time-per-token
               ... all scaled by time-factor-under-load, which ramps
                   1.0 → factor as in-flight requests go 1 → max-num-seqs
```

`n_cached` is the simulated prefix-cache hit count. So a cache hit genuinely lowers
TTFT (rewarding `prefix-cache-affinity-filter`) and saturation genuinely raises it
(rewarding `token-load-scorer`).

> [!IMPORTANT]
> `--latency-calculator=per-token` is mandatory, not a preference. Under the
> `constant` calculator TTFT is a flat number and a cache hit costs exactly as much
> as a miss, which makes the entire experiment inert.

---

## Prerequisites

- Linux x86_64 (macOS instructions are [further down](#macos-apple-silicon))
- `docker`, and your user in the `docker` group — minikube's docker driver refuses
  to run as root:
  ```bash
  sudo usermod -aG docker "$USER"   # then start a new login session
  ```
- `kubectl`, `helm`, `minikube` (≥ v1.38). Tested with helm **v3.16.1** and
  **v4.1.4**; `scripts/down.sh` uses `helm uninstall --ignore-not-found`, which
  needs helm ≥ 3.13.
- `python3` on the host — only used to render the final comparison table
- **~6 GB free disk.** minikube's base image and Kubernetes preload alone are
  ~1 GB before any of this example's images.

```bash
curl -fsSLo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install -m 0755 minikube /usr/local/bin/minikube
```

Set the environment used throughout. The names match the upstream guide.

```bash
export NAMESPACE=llm-d-sim
export RELEASE=llmd
export MODEL=Qwen/Qwen3-32B
export GAIE_VERSION=v1.5.0
export ROUTER_CHART=oci://ghcr.io/llm-d/charts/llm-d-router-standalone
export ROUTER_CHART_VERSION=v0
```

<details>
<summary><b>Versions this was measured against</b></summary>

| Component | Version |
| --- | --- |
| `llm-d-inference-sim` | `v0.9.2` (pinned in `modelserver/sim/kustomization.yaml`) |
| `llm-d-router-standalone` chart | `v0` |
| `llm-d-router-endpoint-picker` | `main` |
| Envoy sidecar | `distroless-v1.33.2` (pulled by the chart) |
| Gateway API Inference Extension | `v1.5.0` |
| minikube / Kubernetes | `v1.38.1` / `v1.35.1` |
| helm | `v3.16.1` (Linux) and `v4.1.4` (macOS) |

> [!WARNING]
> **`v0` and `main` are moving tags.** That is upstream's own default in
> `guides/env.sh`, not a choice made here — but it does mean the chart and EPP image
> you pull are not necessarily the ones measured above, and the numbers may drift.
> Pin by digest if you need byte-reproducibility for a live demo.

`v0.9.2` is a hard floor for the simulator, not a preference:
`--force-dummy-tokenizer` does not exist in `v0.9.0` or earlier, and without it a
real HuggingFace model name makes the simulator require a separate tokenizer render
service.

The three files under `modelserver/base/` are vendored byte-identical from upstream
llm-d; each carries its upstream path, last-change commit, and a drift-check `diff`
recipe in its own header comment. `router/minikube.values.yaml` is a deliberate merge
and its divergences are listed at the top of that file.

</details>

---

## Deploy

Every step below is a copy-pasteable block, so you can see the shape of the
deployment and debug one piece at a time. If you would rather not type,
`./scripts/up.sh` runs exactly this sequence.

### 1. Start minikube

```bash
minikube start --driver=docker --cpus=2 --memory=4g --disk-size=20g
```

2 CPUs is genuinely enough here, but only because the resource requests have been
shrunk — see [the resource table](#the-resource-squeeze).

### 2. Install the Gateway API Inference Extension CRDs

```bash
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml"
```

This installs the `InferencePool` CRD. No controller is needed: in standalone mode
EPP watches the `InferencePool` object itself to learn which pods to route to.

### 3. Create the namespace

```bash
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
```

There is **no HuggingFace secret step**. Upstream needs one to pull model weights;
the simulator downloads nothing.

### 4. Deploy the llm-d router (standalone mode)

```bash
helm upgrade --install "${RELEASE}" "${ROUTER_CHART}" \
  -f router/minikube.values.yaml \
  -n "${NAMESPACE}" --version "${ROUTER_CHART_VERSION}"
```

Standalone mode means an EPP pod with an Envoy sidecar, and no Kubernetes Gateway.
The Envoy sidecar *is* the data plane — EPP only returns an ext_proc verdict over
gRPC — so `proxy.enabled=false` would leave no path for traffic.

> [!TIP]
> If this fails with `failed to authorize: ... 403 Forbidden`, you have stale
> `ghcr.io` credentials in `~/.docker/config.json`. helm tries them and fails
> rather than falling back to anonymous. These charts are public, so:
> ```bash
> D=$(mktemp -d); echo '{}' > "$D/config.json"
> DOCKER_CONFIG="$D" helm upgrade --install ...
> ```
> `scripts/up.sh` does this automatically.

### 5. Deploy the simulator model servers and the baseline Service

```bash
kubectl apply -n "${NAMESPACE}" -k modelserver/sim
```

This creates four simulator replicas plus `sim-plain`, the ordinary ClusterIP
Service used as the A/B baseline. Both select the same `llm-d.ai/role: decode` pods.

### 6. Wait, then look

```bash
kubectl rollout status "deployment/${RELEASE}-epp" -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/sim-decode      -n "${NAMESPACE}" --timeout=300s
kubectl get pods,svc -n "${NAMESPACE}"
```

```
NAME                              READY   STATUS    RESTARTS   AGE
pod/llmd-epp-6dc48d4b74-pn8zm     2/2     Running   0          5s
pod/sim-decode-5788b47779-6rchj   1/1     Running   0          5s
pod/sim-decode-5788b47779-7977k   1/1     Running   0          5s
pod/sim-decode-5788b47779-9xxhp   1/1     Running   0          5s
pod/sim-decode-5788b47779-wpp6h   1/1     Running   0          5s
```

Confirm EPP found the endpoints — you want four `Pod added` lines:

```bash
kubectl logs -n "${NAMESPACE}" "deploy/${RELEASE}-epp" -c epp | grep -c '"msg":"Pod added"'
```

---

## Verify

```bash
EPP_IP=$(kubectl get svc "${RELEASE}-epp" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')

kubectl run curl-test --rm -i --restart=Never -n "${NAMESPACE}" \
  --image=cfmanteiga/alpine-bash-curl-jq:latest \
  --env="EPP=${EPP_IP}" --env="MODEL=${MODEL}" -- /bin/sh -c '
    curl -sS -D /dev/stderr -X POST "http://${EPP}:80/v1/completions" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"${MODEL}\",\"prompt\":\"How are you today?\",\"max_tokens\":10}"'
```

You should get a completion, and in the response headers:

```
x-inference-pod: sim-decode-5788b47779-6rchj
```

That header is the simulator reporting which pod served the request (it comes from
the `POD_NAME` env var, injected via `fieldRef`). The experiment uses it for exact
request→pod attribution rather than inferring from metric deltas.

---

## Run the A/B experiment

```bash
./scripts/drive.sh
```

Defaults: 16 shared prefixes of ~1500 tokens, 400 measured requests at concurrency
8, plus 48 discarded warmup requests, seed 1234. Override any of it:

```bash
REQUESTS=100 CONCURRENCY=4 ./scripts/drive.sh          # quicker
./scripts/drive.sh llmd                                # one arm only
```

Between arms the script does a `rollout restart` to clear cache capacity held by
the previous arm, and `drive.py` additionally salts its prefixes per arm so each
arm starts cold whether or not the restart worked.

### Why the driver runs inside the cluster

`kubectl port-forward svc/...` picks **one** pod and forwards straight to it,
bypassing kube-proxy entirely. Driving the baseline arm through a port-forward
would report 100% of traffic on a single pod — a pure measurement artifact that
looks exactly like a real finding. So `drive.py` is mounted from a ConfigMap and
runs as a Job, hitting both ClusterIPs from inside the cluster.

### Why a fresh connection per request

A single keep-alive connection to a ClusterIP is pinned to one backend for its
lifetime, because kube-proxy load-balances at connection-establishment time. Reusing
connections would measure connection balancing rather than request balancing, and
would flatter the L4 baseline into looking like it does nothing at all. The driver
opens a new connection per request in *both* arms.

---

## Reading the results

The interesting block is the per-prefix breakdown. Baseline:

```
--- prefix -> pod affinity (the thing the distribution table hides) ---
  distinct pods serving each prefix : 4.00 of 4  (1.0 = perfect partition)
  mean concentration on top pod     : 36.2%
    prefix 10 ( 29 reqs, top= 28%): fb2rf:8 ghf49:7 xprxx:7 flh4l:7
    prefix 11 ( 29 reqs, top= 34%): ghf49:10 xprxx:8 flh4l:6 fb2rf:5
```

llm-d:

```
  distinct pods serving each prefix : 1.00 of 4  (1.0 = perfect partition)
  mean concentration on top pod     : 100.0%
    prefix 10 ( 29 reqs, top=100%): 7tz7h:29
    prefix 11 ( 29 reqs, top=100%): 7tz7h:29
```

Sixteen prefixes landed on four pods, four prefixes each, every request for a given
prefix going to the same pod — while per-pod request share stayed within 23–27%.

Two independent measurements of the cache agree, which is worth checking as a
sanity test on your own run: `cached prompt tokens %` comes from each response's
`usage.prompt_tokens_detail.cached_tokens`, and `prefix cache hit rate % (metrics)`
comes from `vllm:prefix_cache_hits / vllm:prefix_cache_queries` deltas scraped from
each pod. On the reference run both read 28.8% and 98.9%.

### Why the baseline is slow, precisely

This is the mechanism the experiment is built to expose, and it is worth being
explicit because a naive version of this demo shows nothing at all.

Each pod is configured with `--kv-cache-size=400` blocks × `--block-size=16` =
**6400 cached tokens ≈ 4 of the workload's 1500-token prefixes**. Four pods hold
~25 600 tokens in aggregate, and the workload's 16 prefixes total ~24 000 tokens.

So the working set fits in the *aggregate* cache — but only if routing partitions
it. Spray every prefix at every pod and each pod is asked to hold all 16 (24 000
tokens into 6400) and thrashes. That is the real-world argument for cache-aware
routing: aggregate cache capacity is only usable if the router partitions the
keyspace.

### Proof: give every pod enough cache and the advantage disappears

The claim above is testable, so it was tested. Re-running the same A/B with
`--kv-cache-size=2000` (32 000 tokens per pod — enough for one pod to hold the
entire 24 000-token working set), changing nothing else:

| metric | baseline (L4) | llm-d (L7) | delta |
| --- | --- | --- | --- |
| prefix cache hit rate | **91.5%** (was 28.8%) | 98.6% | **1.08×** (was 3.43×) |
| TTFT p50 | **230.4 ms** (was 1009.8) | 225.4 ms | **1.02×** (was 8.44×) |
| throughput | 28.15 req/s (was 7.49) | 38.83 req/s | 1.38× (was 4.66×) |
| pods per prefix | 4.00 | 1.12 | — |

The routing advantage on TTFT is **gone** — 230 ms vs 225 ms is a tie. The baseline
did not get worse; it got *better*, from 1009.8 ms to 230.4 ms, because now every
pod can cache everything and no request pays for a miss.

That is the honest scope of this routing strategy: **prefix-cache-aware routing buys
you nothing until your working set exceeds per-replica cache capacity.** It converts
aggregate cache into usable cache. If your aggregate and per-replica capacity are
effectively the same — few replicas, small working set — you are paying for
machinery you do not need.

(Throughput still improves 1.38×, and llm-d's `pods per prefix` rises from 1.00 to
1.12: with capacity no longer scarce, the affinity filter's load gate is freer to
spread a prefix across more than one pod rather than hold stickiness.)

---

## Why these simulator flags

The constants in `modelserver/sim/patch-sim.yaml` were calibrated, not guessed. The
simulator's behaviour was measured directly (`docker run` the image, drive it with
`max_tokens=1` so total time ≈ prefill):

**Prefill is linear in uncached prompt length**, matching
`prefill-overhead + n × prefill-time-per-token`:

| prompt tokens | predicted | measured |
| --- | --- | --- |
| 100 | 80 ms | 83 ms |
| 500 | 200 ms | 203 ms |
| 1000 | 350 ms | 355 ms |
| 1500 | 500 ms | 507 ms |

**A cache hit removes almost all of it.** Streaming a fresh 1500-token prefix, then
the same prefix again:

```
COLD  first chunk @ 512.1 ms
WARM  first chunk @  58.3 ms      → 8.79× TTFT reduction
```

The floor is `--prefill-overhead=50ms`, which is why the speedup is 8.8× and not
the naive 10×. Subsequent chunks arrived 10 ms apart, matching
`--inter-token-latency=10ms`.

**`--time-factor-under-load=4` engages as designed** (`--max-num-seqs=4`):

| concurrency | mean request time |
| --- | --- |
| 1 | 505 ms |
| 2 | 1008 ms |
| 8 | 2135 ms |

**Cache accounting is block-granular.** A 1500-token prefix reports 1488 cached
tokens on a hit, not 1500: `floor(1500/16) = 93` whole blocks × 16 = 1488. Worth
knowing before you wonder why hit rates plateau just under 100%.

`peakPrefillThroughput: 3333` in `router/minikube.values.yaml` follows from the
above — it is `1 / 300us`. The plugin default of `15928` is a Qwen3-32B / 2×H100 /
TP=2 measurement and would understate the estimated TTFT that the filter's
`maxTTFTPenaltyMs` load gate keys off by ~4.8×. **Re-derive it if you change
`--prefill-time-per-token`.**

### The resource squeeze

| Component | Upstream request | Here |
| --- | --- | --- |
| EPP | 4 CPU / 8 Gi | 200m / 512 Mi |
| Envoy sidecar | 4 CPU / 8 Gi | 200m / 256 Mi |
| simulator × 4 | — | 50m / 128 Mi each |
| **total** | **8 CPU / 16 Gi** | **~600m / ~1.3 Gi** |

minikube's own control plane requests ~750m of a 2-CPU node (apiserver 250m,
controller-manager 200m, etcd 100m, scheduler 100m, coredns 100m). Upstream's
values would leave everything `Pending` forever.

---

## Cleanup

```bash
./scripts/down.sh                    # keep the cluster
./scripts/down.sh --delete-cluster   # remove minikube too
```

Or by hand:

```bash
kubectl delete -n "${NAMESPACE}" -k modelserver/sim
helm uninstall "${RELEASE}" -n "${NAMESPACE}"
kubectl delete namespace "${NAMESPACE}"
```

The GAIE CRDs are cluster-scoped and are left in place.

---

## macOS (Apple Silicon)

Verified on macOS 15.1, Apple Silicon, with **Colima** providing the container
runtime. Both required images publish `linux/arm64`, so nothing is emulated.

```bash
brew install colima docker minikube      # `docker` here is the CLI only, not Docker Desktop
colima start --cpu 4 --memory 8 --disk 30
minikube start --driver=docker --cpus=4 --memory=6g
```

From here **every remaining step is byte-identical to the Linux path** — same
`up.sh`, same manifests, same `drive.sh`. That is the reason for choosing the docker
driver on macOS: the two platforms converge after cluster creation.

Measured on Apple Silicon (14-core / 36 GB host, cluster capped at 4 CPU / 8 GB):

| | Linux (2 vCPU VM) | macOS (Apple Silicon) |
| --- | --- | --- |
| `up.sh`, cold | — | 3 m 43 s (mostly image pulls) |
| `up.sh`, images cached | 7.8 s | — |
| `drive.sh`, both arms | 1 m 48 s | 2 m 38 s |
| pods per prefix, baseline → llm-d | 4.00 → 1.00 | **4.00 → 1.00** |
| top-pod concentration | 36.2% → 100.0% | **35.0% → 100.0%** |
| cache hit rate | 28.8% → 98.9% | **25.7% → 98.3%** |
| TTFT p50 improvement | 8.44× | **6.90×** |
| throughput improvement | 4.66× | **4.43×** |

Notes from the macOS run:

- **`brew install docker` is the CLI, not Docker Desktop.** minikube's docker driver
  shells out to the `docker` binary; Colima supplies the daemon behind it. No Docker
  Desktop licence is involved.
- minikube prints `Using Docker Desktop driver with root privileges`. That is a
  cosmetic misdetection of Colima and can be ignored.
- helm **v4.1.4** was used here and helm **v3.16.1** on Linux; the chart installs
  under both.
- The `gcr.io/k8s-minikube/kicbase` pull is ~483 MB and dominated the cold start
  (it ran at ~250 KiB/s on the test connection, roughly 25 minutes). This is a
  one-time cost per minikube version.

<details>
<summary><b>Why not the vfkit driver?</b></summary>

vfkit is attractive on paper — it uses Apple's Virtualization.framework directly,
with no container runtime under it. It was the first thing tried here, and it does
not work out of the box on macOS 15:

```
X Exiting due to GUEST_PROVISION: error provisioning guest: Failed to start host:
  creating host: create: creating: IP address never found in dhcp leases file:
  failed to get IP address: open /var/db/dhcpd_leases: no such file or directory
```

With vfkit's default `nat` network, minikube looks for the VM's address in
`/var/db/dhcpd_leases`, which only exists once macOS's `bootpd` has served a lease.
Switching to `--network=vmnet-shared` gets further but then requires a separate
component:

```
X Exiting due to NOT_FOUND_VMNET_HELPER: failed to validate vmnet-shared network:
  failed to find vmnet-helper at [...]
```

`vmnet-helper` installs root-owned code under `/opt/vmnet-helper` and, on macOS 15
and earlier, also installs `/etc/sudoers.d/vmnet-helper` granting passwordless sudo
for that binary. That is a reasonable trade for some people and not for others, so
this runbook takes the Colima route, which needs no privileged helper and has the
side benefit of making the macOS and Linux instructions identical after
`minikube start`.

If you would rather use vfkit:

```bash
curl -fsSL https://github.com/minikube-machine/vmnet-helper/releases/latest/download/install.sh | bash
minikube start --driver=vfkit --network=vmnet-shared --cpus=4 --memory=8g
```

Read that script before running it — it asks for sudo and installs the sudoers rule.
Untested here.

</details>

---

## Troubleshooting

Every entry here is something that actually happened while building this.

| Symptom | Cause and fix |
| --- | --- |
| Simulator pods `CrashLoopBackOff`, logs show `unknown flag: --force-dummy-tokenizer` | You are on `v0.9.0` or earlier. That flag was added later; `modelserver/sim/kustomization.yaml` pins `v0.9.2` as the floor. |
| Simulator exits with `IP should be defined in the environment (POD_IP) for KV cache to work` | `--enable-kvcache` requires `POD_IP`. The manifest sets it via `fieldRef`; if you copied the container spec elsewhere, carry all three `POD_*` vars. |
| `helm install` → `failed to authorize ... 403 Forbidden` | Stale `ghcr.io` entry in `~/.docker/config.json`. See the tip in step 4. |
| Everything `Pending`, `0/1 nodes available: insufficient cpu` | You are using upstream's resource values, not `router/minikube.values.yaml`. |
| Baseline arm reports 100% of traffic on one pod | You drove it through `kubectl port-forward svc/...`, which bypasses kube-proxy. Use `scripts/drive.sh`. |
| `x-inference-pod` header missing | Envoy lowercases headers; the pod emits `X-Inference-Pod`. Match case-insensitively. |
| Both arms show ~identical cache hit rates | Per-pod cache is large enough to hold the whole working set. Lower `--kv-cache-size` or raise `N_PREFIXES`. |
| A/B numbers much closer than the table above | The router chart (`v0`) and EPP image (`main`) are moving tags — that is upstream's own default in `guides/env.sh` — so you may have a different build than was measured here. Also check per-pod cache capacity, above. |

Useful probes:

```bash
# EPP routing decisions (raise verbosity in router/minikube.values.yaml: epp.flags.v)
kubectl logs -n "${NAMESPACE}" "deploy/${RELEASE}-epp" -c epp -f

# One simulator pod's raw metrics
POD_IP=$(kubectl get pod -n "${NAMESPACE}" -l llm-d.ai/role=decode \
  -o jsonpath='{.items[0].status.podIP}')
kubectl run m --rm -i --restart=Never -n "${NAMESPACE}" --image=curlimages/curl:latest \
  -- curl -s "http://${POD_IP}:8000/metrics" | grep -E 'prefix_cache|num_requests'
```

---

## Where to go next

The simulator supports several things this example deliberately does not use, each
of which maps onto a component in
[`docs/concept-to-llmd.md`](../../docs/concept-to-llmd.md):

- **Precise prefix cache.** With `--enable-kvcache` the simulator publishes real
  KV-cache add/evict events over ZMQ, and EPP registers a
  `precise-prefix-cache-producer` that consumes them. Swapping `approx` → `precise`
  changes the routing *mechanism*, not just its parameters.
- **P/D disaggregation.** See `manifests/disaggregation` upstream, plus
  `--kv-cache-transfer-time-per-token`. Note the simulator deliberately does *not*
  scale KV-transfer time by `time-factor-under-load`, because it models network
  rather than GPU time — a distinction this audience will appreciate.
- **Fault tolerance.** `--failure-injection-rate` and `--failure-types`
  (`rate_limit`, `server_error`, `context_length`, …).
- **Autoscaling.** The simulator exports vLLM-compatible
  `vllm:num_requests_waiting`, which is what llm-d's autoscaling recipes key off.

None of the above is exercised or verified here.

---

## Repo layout

```
llm-d-inference-sim-example/
├── README.md                       this runbook
├── router/
│   └── minikube.values.yaml        optimized-baseline plugins + shrunk resources
├── modelserver/
│   ├── base/                       vendored llm-d modelserver base (4 files)
│   └── sim/
│       ├── kustomization.yaml      image pin + the llm-d.ai/* join labels
│       ├── patch-sim.yaml          simulator flags, resources, POD_* fieldRefs
│       └── plain-service.yaml      the L4 baseline arm
└── scripts/
    ├── up.sh / down.sh             the runbook's commands, in sequence
    ├── drive.sh                    host side: resolve IPs, run Jobs, compare arms
    └── drive.py                    in-cluster driver + evidence table (stdlib only)
```
