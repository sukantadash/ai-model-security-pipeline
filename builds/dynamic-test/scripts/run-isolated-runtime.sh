#!/usr/bin/env bash
# Subtask isolated-runtime: Kata guest + no reach to internal/public systems.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/dynamic-isolated-runtime.json}"
python3 - <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask isolated-runtime --tool kata-runtimeclass --out "${OUT}"
import json, os, socket

findings = []
tool = "kata-runtimeclass"

product = ""
for path in (
    "/sys/class/dmi/id/product_name",
    "/sys/devices/virtual/dmi/id/product_name",
):
    try:
        product = open(path).read().strip()
        break
    except OSError:
        pass

# RUNTIME_CLASS env is not proof of isolation — require guest DMI/virt.
guest = product.lower()
if "kata" not in guest and "qemu" not in guest and "kvm" not in guest:
    findings.append({
        "issue": (
            f"pod is not a Kata/QEMU guest "
            f"(runtimeClass={os.environ.get('RUNTIME_CLASS') or 'unset'}, dmi={product or 'unknown'})"
        ),
        "risk": "critical",
        "tool_used": tool,
    })

def can_connect(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

if can_connect("1.1.1.1", 443):
    findings.append({
        "issue": "public HTTPS egress succeeded (1.1.1.1:443); sandbox must be DNS-only",
        "risk": "critical",
        "tool_used": "networkpolicy",
    })
if can_connect("kubernetes.default.svc", 443):
    findings.append({
        "issue": "reached in-cluster Kubernetes API; isolated runtime must not reach internal systems",
        "risk": "critical",
        "tool_used": "networkpolicy",
    })

print(json.dumps(findings))
PY
