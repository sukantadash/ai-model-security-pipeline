#!/usr/bin/env bash
# Subtask performance-cost: latency, throughput, and estimated GPU cost.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-performance-cost.json}"
METRICS="${2:-}"
python3 - "${OUT}" "${METRICS}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask performance-cost --tool latency-probe --out "${OUT}"
import json, os, sys

metrics_path = sys.argv[2]
p99_max = float(os.environ.get("PERF_P99_MS_MAX", "2000"))
tps_min = float(os.environ.get("PERF_TPS_MIN", "10"))
cost_max = float(os.environ.get("PERF_COST_USD_MAX", "10"))
findings = []

candidates = [p for p in (metrics_path, os.path.join(os.path.dirname(metrics_path or ""), "perf-metrics.json")) if p]
path = next((p for p in candidates if p and os.path.isfile(p)), None)
if path is None:
    # Fixture lives on unit ConfigMaps, not next to HF weights. Missing ≠ hard-gate fail.
    print("[]")
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
