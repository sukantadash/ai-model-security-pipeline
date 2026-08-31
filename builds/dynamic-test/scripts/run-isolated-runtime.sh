#!/usr/bin/env bash
# Subtask isolated-runtime: inspect the sandbox serving pod when SANDBOX_INSPECT_DIR
# is set; otherwise probe this Task pod (unit fixtures).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/dynamic-isolated-runtime.json}"
export SCRIPT_DIR
python3 - <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask isolated-runtime --tool kata-runtimeclass --out "${OUT}"
import json, os, socket
from pathlib import Path

findings = []
inspect_dir = (os.environ.get("SANDBOX_INSPECT_DIR") or "").strip()

def load_json(name):
    path = Path(inspect_dir) / name
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text() or "{}")
    except json.JSONDecodeError:
        return {"error": "invalid json", "path": str(path)}

def items(doc):
    if not isinstance(doc, dict):
        return []
    if isinstance(doc.get("items"), list):
        return [x for x in doc["items"] if isinstance(x, dict)]
    if doc.get("kind"):
        return [doc]
    return []

def allows_public_https(np_doc):
    for pol in items(np_doc):
        spec = pol.get("spec") or {}
        for rule in spec.get("egress") or []:
            ports = rule.get("ports") or []
            port_ok = not ports or any(
                int(p.get("port") or 0) == 443 or str(p.get("port") or "") == "https"
                for p in ports
                if isinstance(p, dict)
            )
            if not port_ok:
                continue
            for dest in rule.get("to") or []:
                block = (dest.get("ipBlock") or {}).get("cidr") or ""
                if block in ("0.0.0.0/0", "::/0"):
                    return True, pol.get("metadata", {}).get("name") or "unknown"
    return False, None

if inspect_dir:
    llmis = load_json("llmis.json")
    pods = load_json("pods.json")
    nps = load_json("networkpolicies.json")
    if llmis is None or (isinstance(llmis, dict) and llmis.get("error")):
        findings.append({
            "issue": f"sandbox LLMInferenceService inspect failed: {(llmis or {}).get('error') or 'missing llmis.json'}",
            "risk": "critical",
            "tool_used": "kata-runtimeclass",
        })
        print(json.dumps(findings))
        raise SystemExit
    kind = (llmis or {}).get("kind")
    if kind != "LLMInferenceService" and not items(llmis):
        findings.append({
            "issue": "sandbox LLMInferenceService not found; isolated-runtime must inspect the serving pod",
            "risk": "critical",
            "tool_used": "kata-runtimeclass",
        })
        print(json.dumps(findings))
        raise SystemExit

    pod_list = items(pods) if pods else []
    runtime = ""
    dmi = ""
    for pod in pod_list:
        runtime = str((pod.get("spec") or {}).get("runtimeClassName") or runtime)
        dmi = str(((pod.get("metadata") or {}).get("annotations") or {}).get("sandbox-dmi") or dmi)
    guest = f"{runtime} {dmi}".lower()
    if "kata" in guest or "qemu" in guest or "kvm" in guest:
        pass
    else:
        findings.append({
            "issue": (
                f"sandbox serving pod is not a Kata/QEMU guest "
                f"(runtimeClass={runtime or 'unset'}; GPU Kata is optional — not a hard-gate critical)"
            ),
            "risk": "medium",
            "tool_used": "kata-runtimeclass",
        })

    if nps is None:
        findings.append({
            "issue": "sandbox NetworkPolicy inspect missing; cannot prove DNS-only egress",
            "risk": "high",
            "tool_used": "networkpolicy",
        })
    else:
        open_https, pol_name = allows_public_https(nps)
        if open_https:
            findings.append({
                "issue": (
                    f"sandbox NetworkPolicy {pol_name} allows 0.0.0.0/0:443; "
                    "serving pod must not have public HTTPS egress"
                ),
                "risk": "critical",
                "tool_used": "networkpolicy",
            })
        np_items = items(nps)
        if not np_items:
            findings.append({
                "issue": "no NetworkPolicy in model-sandbox; serving pod is not isolated",
                "risk": "critical",
                "tool_used": "networkpolicy",
            })
    print(json.dumps(findings))
    raise SystemExit

# Unit / no inspect: probe this Task pod (legacy contract).
product = ""
tool = "kata-runtimeclass"
for path in (
    "/sys/class/dmi/id/product_name",
    "/sys/devices/virtual/dmi/id/product_name",
):
    try:
        product = open(path).read().strip()
        break
    except OSError:
        pass

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
