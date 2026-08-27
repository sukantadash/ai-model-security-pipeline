#!/usr/bin/env python3
"""static-scan subtasks: malware, vulnerabilities, license-compliance."""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TASK = "static-scan"
POLICY_PATH = os.environ.get("STATIC_SCAN_POLICY", "/etc/static-scan/policy.json")
CLAMAV_DB = os.environ.get("CLAMAV_DB", "/var/lib/clamav")
SUBTASKS = ("malware", "vulnerabilities", "license-compliance")

LICENSE_FILE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "NOTICE", "LICENCE")
SPDX_RE = re.compile(
    r"\b(apache-2\.0|mit|bsd-3-clause|bsd-2-clause|gpl-3\.0|gpl-2\.0|agpl-3\.0|"
    r"lgpl-3\.0|mpl-2\.0|cc-by-nc-4\.0|cc-by-4\.0|cc0-1\.0|sspl-1\.0)\b",
    re.I,
)
LICENSE_LINE_RE = re.compile(r"^[Ll]icense\s*[:=]\s*['\"]?([A-Za-z0-9.+_-]+)", re.M)


def load_policy() -> dict:
    return json.loads(Path(POLICY_PATH).read_text())


def run_cmd(argv: list[str], timeout: int) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)


def write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, default=str))


def issue(subtask: str, text: str, risk: str, tool: str, **extra) -> dict:
    row = {
        "issue": text,
        "risk": risk,
        "tool": tool,
        "task": TASK,
        "subtask": subtask,
    }
    row.update(extra)
    return row


MODELAUDIT_IMMEDIATE_RE = re.compile(
    r"(\bexec\s*\(|\beval\s*\(|os\.system|posix\.system|\bsubprocess\b|__reduce__|pickle\.loads)",
    re.I,
)


def is_immediate_fail(row: dict, policy: dict) -> bool:
    tool = str(row.get("tool") or "").lower()
    risk = str(row.get("risk") or "").lower()
    text = str(row.get("issue") or "")
    needles = policy.get("immediate_fail") or {}
    if tool == "clamav" and risk == "critical":
        return True
    if tool == "modelaudit" and risk == "critical":
        return bool(MODELAUDIT_IMMEDIATE_RE.search(text))
    if risk == "critical" and any(n.lower() in text.lower() for n in needles.get("tool_missing_needles") or []):
        return True
    return False


def list_files(model_path: str) -> list[str]:
    files = []
    for path in glob.glob(os.path.join(model_path, "**", "*"), recursive=True):
        if os.path.isfile(path) and not os.path.basename(path).startswith("."):
            files.append(path)
    return files


def magika_label(path: str) -> str:
    try:
        from magika import Magika

        result = Magika().identify_path(Path(path))
        output = getattr(result, "output", result)
        return str(
            getattr(output, "label", None)
            or getattr(output, "ct_label", None)
            or "unknown"
        )
    except Exception:
        try:
            r = run_cmd(["magika", "-j", path], timeout=30)
            if r.returncode == 0 and r.stdout.strip():
                data = json.loads(r.stdout)
                if isinstance(data, list) and data:
                    data = data[0]
                return str(
                    data.get("output", {}).get("label")
                    or data.get("result", {}).get("label")
                    or "unknown"
                )
        except Exception:
            pass
        return "unknown"


def pickle_like(path: str, policy: dict, magika_types: dict) -> bool:
    ext = Path(path).suffix.lower()
    label = magika_types.get(path, "").lower()
    if "pickle" in label or "pytorch" in label:
        return True
    if ext not in policy.get("fickling_extensions", []):
        return False
    if ext == ".bin":
        return any(token in label for token in ("pickle", "pytorch", "zip", "python"))
    return True


def subtask_malware(model_path: str, policy: dict) -> list[dict]:
    sub = "malware"
    issues: list[dict] = []
    files = list_files(model_path)
    native = {n.lower() for n in policy.get("magika_native_labels", [])}
    magika_types = {}
    for path in files:
        label = magika_label(path)
        magika_types[path] = label
        if label.lower() in native:
            issues.append(
                issue(sub, f"native executable detected ({label}): {path}", "high", "magika", file=path)
            )

    try:
        from modelaudit.core import scan_model_directory_or_file

        results = scan_model_directory_or_file(
            model_path, timeout=policy["timeouts"]["modelaudit_seconds"]
        )
        if not isinstance(results, dict):
            results = json.loads(json.dumps(results, default=lambda o: getattr(o, "__dict__", str(o))))
        for item in results.get("issues") or []:
            sev = str(item.get("severity", "")).lower()
            risk = {"critical": "critical", "error": "high", "warning": "medium", "info": "low"}.get(sev, "medium")
            issues.append(
                issue(
                    sub,
                    item.get("message") or "modelaudit finding",
                    risk,
                    "modelaudit",
                    location=item.get("location", ""),
                )
            )
    except Exception as exc:
        raw = Path("/tmp/modelaudit.json")
        try:
            r = run_cmd(
                [
                    "modelaudit",
                    "scan",
                    model_path,
                    "--format",
                    "json",
                    "--output",
                    str(raw),
                    "--timeout",
                    str(policy["timeouts"]["modelaudit_seconds"]),
                    "--max-size",
                    "20GB",
                ],
                timeout=policy["timeouts"]["modelaudit_seconds"] + 30,
            )
            payload = json.loads(raw.read_text() or "{}") if raw.exists() else {}
            for item in payload.get("issues") or []:
                sev = str(item.get("severity", "")).lower()
                risk = {"critical": "critical", "error": "high", "warning": "medium"}.get(sev, "medium")
                issues.append(issue(sub, item.get("message") or "modelaudit finding", risk, "modelaudit"))
            if not payload.get("issues") and r.returncode not in (0, 1):
                issues.append(issue(sub, f"modelaudit failed: {exc}", "critical", "modelaudit"))
        except Exception as exc2:
            issues.append(issue(sub, f"modelaudit not usable: {exc2}", "critical", "modelaudit"))

    candidates = [
        p
        for p in files
        if pickle_like(p, policy, magika_types)
        and os.path.getsize(p) <= policy.get("fickling_max_bytes", 524288000)
    ][: policy.get("fickling_max_files", 40)]
    for path in candidates:
        try:
            r = run_cmd(
                ["python3", "-m", "fickling", "--check", path],
                timeout=policy["timeouts"]["fickling_seconds"],
            )
        except Exception as exc:
            issues.append(issue(sub, f"fickling error on {path}: {exc}", "medium", "fickling", file=path))
            continue
        if r.returncode != 0:
            issues.append(
                issue(
                    sub,
                    f"unlisted pickle import / allowlist violation: {path}",
                    "high",
                    "fickling",
                    file=path,
                )
            )

    try:
        out = Path("/tmp/modelscan.json")
        r = run_cmd(
            ["modelscan", "-p", model_path, "-r", "json", "-o", str(out)],
            timeout=policy["timeouts"]["modelscan_seconds"],
        )
        payload = json.loads(out.read_text() or "{}") if out.exists() else {}
        if not payload and r.stdout.strip().startswith("{"):
            payload = json.loads(r.stdout)
        for item in payload.get("issues") or []:
            sev = str(item.get("severity", item.get("severity_name", ""))).upper()
            risk = {"CRITICAL": "critical", "HIGH": "high", "MEDIUM": "medium", "LOW": "low"}.get(sev, "medium")
            issues.append(
                issue(
                    sub,
                    item.get("description") or item.get("message") or "modelscan finding",
                    risk,
                    "modelscan",
                )
            )
    except FileNotFoundError:
        issues.append(issue(sub, "modelscan not installed", "critical", "modelscan"))
    except Exception as exc:
        issues.append(issue(sub, f"modelscan error: {exc}", "medium", "modelscan"))

    argv = [
        "clamscan",
        f"--database={CLAMAV_DB}",
        "--infected",
        "--recursive",
        f"--max-filesize={policy['clamav']['max_filesize']}",
        f"--max-scansize={policy['clamav']['max_scansize']}",
        "--no-summary",
    ]
    for pattern in policy["clamav"].get("exclude_globs", []):
        argv.append(f"--exclude={pattern}")
    argv.append(model_path)
    try:
        r = run_cmd(argv, timeout=policy["timeouts"]["clamav_seconds"])
        for line in (r.stdout or "").splitlines():
            if line.endswith(" FOUND"):
                issues.append(issue(sub, line.strip(), "critical", "clamav"))
        if r.returncode not in (0, 1):
            issues.append(issue(sub, (r.stderr or r.stdout or "clamscan error")[-400:], "medium", "clamav"))
    except FileNotFoundError:
        issues.append(issue(sub, "clamscan not installed", "critical", "clamav"))
    except Exception as exc:
        issues.append(issue(sub, f"clamav error: {exc}", "medium", "clamav"))

    return issues


def subtask_vulnerability(model_path: str, policy: dict) -> list[dict]:
    sub = "vulnerabilities"
    issues: list[dict] = []
    syft_out = Path("/tmp/syft.json")
    grype_out = Path("/tmp/grype.json")
    try:
        r = run_cmd(
            [
                "syft",
                f"dir:{model_path}",
                "--exclude",
                "**/*.safetensors",
                "--exclude",
                "**/*.gguf",
                "--exclude",
                "**/*.ggml",
                "-o",
                f"json={syft_out}",
            ],
            timeout=policy["timeouts"]["syft_seconds"],
        )
        if r.returncode != 0 and not syft_out.exists():
            r = run_cmd(
                ["syft", f"dir:{model_path}", "-o", "json"],
                timeout=policy["timeouts"]["syft_seconds"],
            )
            if r.stdout.strip().startswith("{"):
                write_json(syft_out, json.loads(r.stdout))
        if not syft_out.exists():
            issues.append(issue(sub, (r.stderr or r.stdout or "syft produced no SBOM")[-400:], "critical", "syft"))
            return issues
    except FileNotFoundError:
        issues.append(issue(sub, "syft not installed", "critical", "syft"))
        return issues
    except Exception as exc:
        issues.append(issue(sub, f"syft error: {exc}", "critical", "syft"))
        return issues

    try:
        g = run_cmd(
            ["grype", f"sbom:{syft_out}", "-o", "json"],
            timeout=policy["timeouts"]["grype_seconds"],
        )
        payload = {}
        if g.stdout.strip().startswith("{"):
            payload = json.loads(g.stdout)
            write_json(grype_out, payload)
        elif grype_out.exists():
            payload = json.loads(grype_out.read_text() or "{}")
        if g.returncode not in (0, 1) and not payload.get("matches"):
            issues.append(issue(sub, (g.stderr or g.stdout or "grype error")[-400:], "high", "grype"))
        risk_map = {
            "critical": "critical",
            "high": "high",
            "medium": "medium",
            "low": "low",
            "negligible": "low",
            "unknown": "low",
        }
        for match in payload.get("matches") or []:
            vuln = match.get("vulnerability") or {}
            sev = str(vuln.get("severity", "unknown")).lower()
            cve = vuln.get("id", "CVE")
            artifact = (match.get("artifact") or {}).get("name", "")
            issues.append(
                issue(
                    sub,
                    f"{cve} in {artifact}".strip(),
                    risk_map.get(sev, "medium"),
                    "grype",
                    cve=cve,
                    package=artifact,
                )
            )
    except FileNotFoundError:
        issues.append(issue(sub, "grype not installed", "critical", "grype"))
    except Exception as exc:
        issues.append(issue(sub, f"grype error: {exc}", "high", "grype"))
    return issues


def normalize_license(value: str) -> str:
    text = value.strip().lower().replace(" ", "-")
    aliases = {
        "apache2": "apache-2.0",
        "apache-2": "apache-2.0",
        "apache": "apache-2.0",
        "bsd": "bsd-3-clause",
        "gpl3": "gpl-3.0",
        "gplv3": "gpl-3.0",
        "agpl3": "agpl-3.0",
        "llama-3.1": "llama3.1",
        "llama-3": "llama3",
        "open-rail": "openrail",
    }
    return aliases.get(text, text)


def collect_license_strings(model_path: str, files: list[str]) -> list[str]:
    found: list[str] = []
    syft_out = Path("/tmp/syft.json")
    if syft_out.exists():
        try:
            sbom = json.loads(syft_out.read_text() or "{}")
            for artifact in sbom.get("artifacts") or sbom.get("components") or []:
                for lic in artifact.get("licenses") or []:
                    if isinstance(lic, dict):
                        found.append(str(lic.get("value") or lic.get("spdxExpression") or ""))
                    else:
                        found.append(str(lic))
        except json.JSONDecodeError:
            pass
    else:
        try:
            r = run_cmd(
                [
                    "syft",
                    f"dir:{model_path}",
                    "--exclude",
                    "**/*.safetensors",
                    "-o",
                    "json",
                ],
                timeout=300,
            )
            if r.stdout.strip().startswith("{"):
                sbom = json.loads(r.stdout)
                for artifact in sbom.get("artifacts") or []:
                    for lic in artifact.get("licenses") or []:
                        if isinstance(lic, dict):
                            found.append(str(lic.get("value") or ""))
                        else:
                            found.append(str(lic))
        except Exception:
            pass

    for path in files:
        name = os.path.basename(path)
        if name in LICENSE_FILE_NAMES or name.upper().startswith("LICENSE"):
            try:
                text = Path(path).read_text(errors="ignore")[:8000]
            except OSError:
                continue
            found.extend(SPDX_RE.findall(text))
            if "apache license" in text.lower():
                found.append("apache-2.0")
            if "permission is hereby granted, free of charge" in text.lower():
                found.append("mit")
        if name in ("config.json", "tokenizer_config.json"):
            try:
                data = json.loads(Path(path).read_text() or "{}")
                for key in ("license", "licence", "license_name"):
                    if data.get(key):
                        found.append(str(data[key]))
            except (OSError, json.JSONDecodeError):
                pass
        if name.lower().startswith("readme"):
            try:
                text = Path(path).read_text(errors="ignore")[:8000]
            except OSError:
                continue
            found.extend(LICENSE_LINE_RE.findall(text))
            found.extend(SPDX_RE.findall(text))
    return [normalize_license(v) for v in found if v and v.lower() not in ("null", "none", "unknown")]


def subtask_license(model_path: str, policy: dict) -> list[dict]:
    sub = "license-compliance"
    issues: list[dict] = []
    files = list_files(model_path)
    detected = sorted(set(collect_license_strings(model_path, files)))
    allow = {normalize_license(x) for x in policy["licenses"]["allow"]}
    copyleft = {normalize_license(x) for x in policy["licenses"]["copyleft"]}
    deny = {normalize_license(x) for x in policy["licenses"]["deny"]}
    if not detected:
        issues.append(issue(sub, "no OSS license detected in model artifacts", "high", "license-files"))
        return issues
    for lic in detected:
        if lic in deny:
            issues.append(issue(sub, f"denied license for commercial use: {lic}", "critical", "license-files", license=lic))
        elif lic in copyleft:
            issues.append(issue(sub, f"copyleft license requires review: {lic}", "high", "license-files", license=lic))
        elif lic not in allow:
            issues.append(issue(sub, f"unlisted license: {lic}", "medium", "license-files", license=lic))
    return issues


HANDLERS = {
    "malware": subtask_malware,
    "vulnerabilities": subtask_vulnerability,
    "license-compliance": subtask_license,
}


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: static_scan.py MODEL_PATH OUT_JSON SUBTASK", file=sys.stderr)
        return 2
    model_path, out_path, subtask = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    if subtask not in HANDLERS:
        print(f"unknown subtask {subtask}; expected {SUBTASKS}", file=sys.stderr)
        return 2
    policy = load_policy()
    issues = []
    if not os.path.isdir(model_path):
        issues.append(issue(subtask, f"model path missing: {model_path}", "critical", "static-scan"))
    else:
        issues = HANDLERS[subtask](model_path, policy)
    for row in issues:
        if is_immediate_fail(row, policy):
            row["immediate_fail"] = True
    payload = {"task": TASK, "subtask": subtask, "issues": issues}
    write_json(out_path, payload)
    print(json.dumps(payload, indent=2))
    fail_closed = os.environ.get("STATIC_SCAN_IMMEDIATE_FAIL", "true").lower() in ("1", "true", "yes")
    if fail_closed and any(row.get("immediate_fail") for row in issues):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
