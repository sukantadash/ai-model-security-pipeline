#!/usr/bin/env bash
# Subtask performance-cost: latency, throughput, and estimated GPU cost.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-performance-cost.json}"
METRICS="${2:-}"
export SCRIPT_DIR
python3 - "${OUT}" "${METRICS}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask performance-cost --tool latency-probe --out "${OUT}"
import json, os, sys, statistics
sys.path.insert(0, os.environ.get("SCRIPT_DIR", "/scripts"))

metrics_path = sys.argv[2]
p99_max = float(os.environ.get("PERF_P99_MS_MAX", "2000"))
tps_min = float(os.environ.get("PERF_TPS_MIN", "10"))
cost_max = float(os.environ.get("PERF_COST_USD_MAX", "10"))
findings = []
endpoint = (os.environ.get("MODEL_ENDPOINT") or "").strip()

def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(round((q / 100.0) * (len(ordered) - 1)))))
    return float(ordered[idx])

def emit_from_metrics(p99, tps, cost):
    out = []
    if p99 is None and tps is None and (cost or 0) == 0:
        out.append({
            "issue": "performance metrics file has no latency, throughput, or cost fields",
            "risk": "high",
            "tool_used": "latency-probe",
        })
        return out
    if p99 is not None and float(p99) > p99_max:
        out.append({
            "issue": f"p99 latency {float(p99):.1f} ms exceeded ceiling {p99_max:.1f} ms",
            "risk": "high",
            "tool_used": "latency-probe",
        })
    if tps is not None and float(tps) < tps_min:
        out.append({
            "issue": f"throughput {float(tps):.2f} tokens/sec below minimum {tps_min:.2f}",
            "risk": "high",
            "tool_used": "latency-probe",
        })
    if cost is not None and float(cost) > cost_max:
        out.append({
            "issue": f"estimated GPU cost ${float(cost):.2f} exceeded budget ${cost_max:.2f}",
            "risk": "medium",
            "tool_used": "cost-model",
        })
    return out

if endpoint:
    import vllm_client
    n = int(os.environ.get("PERF_LIVE_REQUESTS", "8"))
    latencies = []
    tokens = 0
    wall = 0.0
    for _ in range(n):
        result = vllm_client.chat(endpoint, "Reply with the word ok.", max_tokens=8, timeout=120)
        if not result.get("ok"):
            findings.append({
                "issue": f"llm endpoint unreachable: {result.get('error')}",
                "risk": "critical",
                "tool_used": "latency-probe",
            })
            print(json.dumps(findings))
            raise SystemExit
        latencies.append(float(result.get("latency_ms") or 0))
        tokens += int(result.get("completion_tokens") or len(str(result.get("text") or "").split()))
        wall += float(result.get("latency_ms") or 0) / 1000.0
    p99 = percentile(latencies, 99)
    tps = (tokens / wall) if wall > 0 else 0.0
    usd_per_hour = float(os.environ.get("PERF_USD_PER_GPU_HOUR", "2.5"))
    cost = (wall / 3600.0) * usd_per_hour
    findings.extend(emit_from_metrics(p99, tps, cost))
    print(json.dumps(findings))
    raise SystemExit

candidates = [p for p in (metrics_path, os.path.join(os.path.dirname(metrics_path or ""), "perf-metrics.json")) if p]
path = next((p for p in candidates if p and os.path.isfile(p)), None)
if path is None:
    findings.append({
        "issue": "llm endpoint not provided",
        "risk": "critical",
        "tool_used": "latency-probe",
    })
    print(json.dumps(findings))
    raise SystemExit

try:
    data = json.loads(open(path).read() or "{}")
except json.JSONDecodeError:
    findings.append({
        "issue": "performance metrics file is not valid JSON",
        "risk": "high",
        "tool_used": "latency-probe",
    })
    print(json.dumps(findings))
    raise SystemExit

if not isinstance(data, dict):
    data = {}

p99 = data.get("latency_p99_ms")
tps = data.get("tokens_per_sec")
gpu_hours = float(data.get("gpu_hours") or 0)
usd_per_hour = float(data.get("usd_per_gpu_hour") or 0)
cost = float(data.get("estimated_usd") or (gpu_hours * usd_per_hour))

if p99 is None and tps is None and cost == 0:
    findings.append({
        "issue": "performance metrics file has no latency, throughput, or cost fields",
        "risk": "high",
        "tool_used": "latency-probe",
    })
    print(json.dumps(findings))
    raise SystemExit

if p99 is not None and float(p99) > p99_max:
    findings.append({
        "issue": f"p99 latency {float(p99):.1f} ms exceeded ceiling {p99_max:.1f} ms",
        "risk": "high",
        "tool_used": "latency-probe",
    })
if tps is not None and float(tps) < tps_min:
    findings.append({
        "issue": f"throughput {float(tps):.2f} tokens/sec below minimum {tps_min:.2f}",
        "risk": "high",
        "tool_used": "latency-probe",
    })
if cost > cost_max:
    findings.append({
        "issue": f"estimated GPU cost ${cost:.2f} exceeded budget ${cost_max:.2f}",
        "risk": "medium",
        "tool_used": "cost-model",
    })

print(json.dumps(findings))
PY
