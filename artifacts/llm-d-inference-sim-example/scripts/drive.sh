#!/usr/bin/env bash
# Run the A/B routing experiment: baseline (plain kube-proxy Service) vs llm-d
# (Envoy + EPP), same simulator pods, same workload, same seed.
#
# drive.py runs as a Job INSIDE the cluster, because `kubectl port-forward
# svc/...` resolves to a single pod and bypasses kube-proxy -- driving the
# baseline from the host would report all traffic on one pod as an artifact.
#
# Usage:  ./scripts/drive.sh [arm ...]        # default: both arms
#         REQUESTS=100 ./scripts/drive.sh     # override any drive.py env var
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-d-sim}"
RELEASE="${RELEASE:-llmd}"
DRIVER_IMAGE="${DRIVER_IMAGE:-python:3.12-alpine}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Workload knobs -- exported into the Job. See drive.py for meanings.
export MODEL="${MODEL:-Qwen/Qwen3-32B}"
export N_PREFIXES="${N_PREFIXES:-16}"
export PREFIX_TOKENS="${PREFIX_TOKENS:-1500}"
export REQUESTS="${REQUESTS:-400}"
export WARMUP="${WARMUP:-40}"
export CONCURRENCY="${CONCURRENCY:-16}"
export SEED="${SEED:-1234}"
export MAX_TOKENS="${MAX_TOKENS:-8}"

ARMS=("$@")
[[ ${#ARMS[@]} -eq 0 ]] && ARMS=(baseline llmd)

resolve_endpoint() {
  case "$1" in
    baseline) echo "http://$(kubectl get svc sim-plain -n "$NAMESPACE" \
                    -o jsonpath='{.spec.clusterIP}'):8000" ;;
    llmd)     echo "http://$(kubectl get svc "${RELEASE}-epp" -n "$NAMESPACE" \
                    -o jsonpath='{.spec.clusterIP}'):80" ;;
    *) echo "unknown arm: $1" >&2; exit 1 ;;
  esac
}

pod_endpoints() {
  kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode \
    -o jsonpath='{range .items[*]}{.status.podIP}:8000,{end}' | sed 's/,$//'
}

reset_cache() {
  # Belt and braces. drive.py already salts its prefixes per arm so each arm is
  # cold regardless, but restarting also clears cache CAPACITY held by the
  # previous arm -- and capacity is the variable this experiment turns on.
  echo "--> resetting simulator cache (rollout restart)"
  kubectl rollout restart deployment/sim-decode -n "$NAMESPACE" >/dev/null
  kubectl rollout status deployment/sim-decode -n "$NAMESPACE" --timeout=180s >/dev/null
  # Give EPP a moment to observe the new endpoints before we start sending.
  sleep 5
}

kubectl create configmap sim-driver -n "$NAMESPACE" \
  --from-file=drive.py="${HERE}/drive.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

TMPDIR_OUT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_OUT"' EXIT

for ARM in "${ARMS[@]}"; do
  reset_cache
  ENDPOINT="$(resolve_endpoint "$ARM")"
  POD_ENDPOINTS="$(pod_endpoints)"
  echo "--> arm=$ARM endpoint=$ENDPOINT"

  kubectl delete job "sim-driver-$ARM" -n "$NAMESPACE" --ignore-not-found >/dev/null

  kubectl apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: sim-driver-$ARM
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: driver
          configMap:
            name: sim-driver
      containers:
        - name: driver
          image: ${DRIVER_IMAGE}
          command: ["python3", "/driver/drive.py"]
          volumeMounts:
            - name: driver
              mountPath: /driver
          resources:
            requests:
              cpu: "200m"
              memory: 128Mi
            limits:
              memory: 512Mi
          env:
            - {name: ARM,           value: "$ARM"}
            - {name: ENDPOINT,      value: "$ENDPOINT"}
            - {name: POD_ENDPOINTS, value: "$POD_ENDPOINTS"}
            - {name: MODEL,         value: "$MODEL"}
            - {name: N_PREFIXES,    value: "$N_PREFIXES"}
            - {name: PREFIX_TOKENS, value: "$PREFIX_TOKENS"}
            - {name: REQUESTS,      value: "$REQUESTS"}
            - {name: WARMUP,        value: "$WARMUP"}
            - {name: CONCURRENCY,   value: "$CONCURRENCY"}
            - {name: SEED,          value: "$SEED"}
            - {name: MAX_TOKENS,    value: "$MAX_TOKENS"}
EOF

  kubectl wait --for=condition=complete "job/sim-driver-$ARM" -n "$NAMESPACE" \
    --timeout=900s >/dev/null 2>&1 || true
  kubectl logs -n "$NAMESPACE" "job/sim-driver-$ARM" | tee "$TMPDIR_OUT/$ARM.txt"

  if ! grep -q '^JSON_SUMMARY:' "$TMPDIR_OUT/$ARM.txt"; then
    echo "!! arm $ARM did not complete; see logs above" >&2
    kubectl get pods -n "$NAMESPACE" -l "job-name=sim-driver-$ARM" >&2 || true
    exit 1
  fi
  echo
done

# Comparison table, only when both arms ran.
if [[ -f "$TMPDIR_OUT/baseline.txt" && -f "$TMPDIR_OUT/llmd.txt" ]]; then
  python3 - "$TMPDIR_OUT/baseline.txt" "$TMPDIR_OUT/llmd.txt" <<'PY'
import json, sys

def load(p):
    for line in open(p):
        if line.startswith("JSON_SUMMARY:"):
            return json.loads(line.split("JSON_SUMMARY:", 1)[1])
    raise SystemExit("no JSON_SUMMARY in %s" % p)

b, l = load(sys.argv[1]), load(sys.argv[2])

def ratio(bv, lv, lower_is_better=True):
    if not bv or not lv:
        return "n/a"
    r = bv / lv if lower_is_better else lv / bv
    return "%.2fx %s" % (r, "better" if r >= 1 else "WORSE")

rows = [
    ("pods serving each prefix", b["pods_per_prefix"], l["pods_per_prefix"],
     ratio(b["pods_per_prefix"], l["pods_per_prefix"])),
    ("top-pod concentration %", b["top_pod_concentration_pct"],
     l["top_pod_concentration_pct"],
     ratio(b["top_pod_concentration_pct"], l["top_pod_concentration_pct"], False)),
    ("cached prompt tokens %", b["cached_pct"], l["cached_pct"],
     ratio(b["cached_pct"], l["cached_pct"], lower_is_better=False)),
    ("prefix cache hit rate % (metrics)", b["metrics_hit_rate_pct"],
     l["metrics_hit_rate_pct"],
     ratio(b["metrics_hit_rate_pct"], l["metrics_hit_rate_pct"], False)),
    ("TTFT p50 (ms)", b["ttft_p50"], l["ttft_p50"], ratio(b["ttft_p50"], l["ttft_p50"])),
    ("TTFT p90 (ms)", b["ttft_p90"], l["ttft_p90"], ratio(b["ttft_p90"], l["ttft_p90"])),
    ("TTFT p99 (ms)", b["ttft_p99"], l["ttft_p99"], ratio(b["ttft_p99"], l["ttft_p99"])),
    ("throughput (req/s)", b["rps"], l["rps"], ratio(b["rps"], l["rps"], False)),
]

print("=" * 78)
print("A/B COMPARISON  (same pods, same workload, same seed)")
print("=" * 78)
print("%-36s %12s %12s  %s" % ("metric", "baseline(L4)", "llm-d(L7)", "delta"))
for name, bv, lv, d in rows:
    print("%-36s %12s %12s  %s" % (name, bv, lv, d))
print()
print("request distribution across pods:")
for arm, s in (("baseline(L4)", b), ("llm-d(L7)", l)):
    d = s["distribution"]
    tot = sum(d.values()) or 1
    print("  %-13s %s" % (arm, "  ".join(
        "%s=%d(%.0f%%)" % (k.split("-")[-1], v, 100.0 * v / tot)
        for k, v in sorted(d.items()))))
PY
fi
