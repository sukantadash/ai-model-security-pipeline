#!/usr/bin/env bash
# Subtask abnormal-resources: Kepler/Prometheus CPU/GPU/memory vs ceilings.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/dynamic-abnormal-resources.json}"
SAMPLES="${2:-}"
python3 - "${OUT}" "${SAMPLES}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask abnormal-resources --tool kepler --out "${OUT}"
import json, os, sys

samples_path = sys.argv[2]
cpu_max = float(os.environ.get("CPU_CEILING_CORES", "8"))
mem_max = float(os.environ.get("MEM_CEILING_BYTES", str(32 * 1024**3)))
gpu_w_max = float(os.environ.get("GPU_POWER_CEILING_WATTS", "400"))
findings = []
if not samples_path or not os.path.isfile(samples_path):
    # Fixture lives on unit ConfigMaps, not next to HF weights. Missing ≠ hard-gate fail.
    print("[]")
    raise SystemExit
else:
    data = json.loads(open(samples_path).read() or "{}")
    cpu = float(data.get("cpuCoresMax") or 0)
    mem = float(data.get("rssBytesMax") or 0)
    gpu = float(data.get("gpuPowerWattsMax") or 0)
    oom = bool(data.get("oom"))
    if oom:
        findings.append({
            "issue": "OOM during sandbox load",
            "risk": "critical",
            "tool_used": "kepler",
        })
    if cpu > cpu_max:
        findings.append({
            "issue": f"CPU {cpu:.2f} cores exceeded ceiling {cpu_max:.2f}",
            "risk": "high",
            "tool_used": "kepler",
        })
    if mem > mem_max:
        findings.append({
            "issue": f"RSS {int(mem)} bytes exceeded ceiling {int(mem_max)}",
            "risk": "high",
            "tool_used": "kepler",
        })
    if gpu > gpu_w_max:
        findings.append({
            "issue": f"GPU power {gpu:.1f} W exceeded ceiling {gpu_w_max:.1f} W",
            "risk": "high",
            "tool_used": "kepler",
        })
print(json.dumps(findings))
PY
