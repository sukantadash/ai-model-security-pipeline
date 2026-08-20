#!/usr/bin/env bash
set -euo pipefail
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/static.json}"
mkdir -p "$(dirname "$OUT")"

python3 - <<PY
import json, os, subprocess, glob

model_path = "${MODEL_PATH}"
out_path = "${OUT}"
findings = []
status = "pass"

for path in list(glob.glob(os.path.join(model_path, "**", "*"), recursive=True))[:200]:
    if not os.path.isfile(path):
        continue
    if os.path.basename(path).startswith("."):
        continue
    try:
        r = subprocess.run(["magika", "-i", path], capture_output=True, text=True, timeout=30)
        magika_type = (r.stdout or r.stderr or "").strip().splitlines()[-1] if r.returncode == 0 else "unknown"
        findings.append({"file": path, "magika_type": magika_type})
    except Exception as exc:
        findings.append({"file": path, "magika_error": str(exc)})

if os.path.isdir(model_path):
    try:
        r = subprocess.run(["modelaudit", "scan", model_path], capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            status = "fail"
            findings.append({"tool": "modelaudit", "detail": (r.stdout or r.stderr)[-500:]})
    except FileNotFoundError:
        findings.append({"tool": "modelaudit", "detail": "not installed"})

for pkl in glob.glob(os.path.join(model_path, "**", "*.pkl"), recursive=True):
    try:
        r = subprocess.run(["python3", "-m", "fickling", "--check", pkl], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            status = "fail"
            findings.append({"tool": "fickling", "file": pkl, "detail": "allowlist violation"})
    except Exception as exc:
        findings.append({"tool": "fickling", "file": pkl, "error": str(exc)})

payload = {"status": status, "scanner": "static-scan", "model": model_path, "findings": findings}
with open(out_path, "w") as fh:
    json.dump(payload, fh, indent=2)
print(json.dumps(payload))
raise SystemExit(0 if status == "pass" else 1)
PY
