#!/usr/bin/env bash
# Subtask stability-check: latency distribution / sporadic slowdowns.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-stability.json}"
SAMPLES="${2:-}"
export SCRIPT_DIR
python3 - "${OUT}" "${SAMPLES}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask stability-check --tool latency-distribution --out "${OUT}"
import json, os, statistics, sys
sys.path.insert(0, os.environ.get("SCRIPT_DIR", "/scripts"))

samples_path = sys.argv[2]
ratio_max = float(os.environ.get("STABILITY_P99_P50_RATIO_MAX", "3.0"))
timeout_max = float(os.environ.get("STABILITY_TIMEOUT_RATE_MAX", "0.05"))
findings = []
endpoint = (os.environ.get("MODEL_ENDPOINT") or "").strip()

if endpoint:
    import vllm_client
    n = int(os.environ.get("STABILITY_LIVE_REQUESTS", "10"))
    health = vllm_client.health(endpoint, timeout=10)
    models = vllm_client.models(endpoint, timeout=10) if not health.get("ok") else {"ok": True}
    if not health.get("ok") and not models.get("ok"):
        findings.append({
            "issue": f"llm endpoint unreachable: {health.get('error') or models.get('error') or endpoint}",
            "risk": "critical",
            "tool_used": "latency-distribution",
        })
        print(json.dumps(findings))
        raise SystemExit
    latencies = []
    timeouts = 0
    for _ in range(n):
        result = vllm_client.chat(endpoint, "Reply with the word ok.", max_tokens=8, timeout=120)
        if not result.get("ok"):
            timeouts += 1
            continue
        latencies.append(float(result.get("latency_ms") or 0))
    data = {"latencies_ms": latencies, "timeouts": timeouts, "requests": n}
else:
    candidates = [p for p in (samples_path, os.path.join(os.path.dirname(samples_path or ""), "latency-samples.json")) if p]
    path = next((p for p in candidates if p and os.path.isfile(p)), None)
    if path is None:
        findings.append({
            "issue": "llm endpoint not provided",
            "risk": "critical",
            "tool_used": "latency-distribution",
        })
        print(json.dumps(findings))
        raise SystemExit
    try:
        data = json.loads(open(path).read() or "{}")
    except json.JSONDecodeError:
        findings.append({
            "issue": "latency samples file is not valid JSON",
            "risk": "high",
            "tool_used": "latency-distribution",
        })
        print(json.dumps(findings))
        raise SystemExit

if isinstance(data, list):
    latencies = [float(x) for x in data]
    timeouts = 0
    requests = len(latencies)
else:
    latencies = [float(x) for x in (data.get("latencies_ms") or [])]
    timeouts = int(data.get("timeouts") or 0)
    requests = int(data.get("requests") or len(latencies) or 0)

if not latencies and requests == 0:
    findings.append({
        "issue": "latency samples file has no request measurements",
        "risk": "high",
        "tool_used": "latency-distribution",
    })
    print(json.dumps(findings))
    raise SystemExit

if latencies:
    ordered = sorted(latencies)
    def percentile(values, q):
        if not values:
            return 0.0
        idx = min(len(values) - 1, max(0, int(round((q / 100.0) * (len(values) - 1)))))
        return float(values[idx])
    p50 = percentile(ordered, 50)
    p99 = percentile(ordered, 99)
    ratio = (p99 / p50) if p50 > 0 else float("inf")
    if ratio > ratio_max:
        findings.append({
            "issue": (
                f"sporadic slowdown: p99/p50 latency ratio {ratio:.1f} "
                f"(p50={p50:.1f} ms, p99={p99:.1f} ms) exceeded {ratio_max:.1f}"
            ),
            "risk": "high",
            "tool_used": "latency-distribution",
        })
    if len(latencies) >= 2:
        stdev = statistics.pstdev(latencies)
        mean = statistics.fmean(latencies)
        if mean > 0 and (stdev / mean) > 1.0:
            findings.append({
                "issue": f"latency jitter stdev/mean {stdev / mean:.2f} indicates unstable tail latency",
                "risk": "medium",
                "tool_used": "latency-distribution",
            })

if requests > 0:
    rate = timeouts / float(requests)
    if rate > timeout_max:
        findings.append({
            "issue": f"timeout rate {rate:.2f} exceeded ceiling {timeout_max:.2f}",
            "risk": "high",
            "tool_used": "latency-distribution",
        })

print(json.dumps(findings))
PY
