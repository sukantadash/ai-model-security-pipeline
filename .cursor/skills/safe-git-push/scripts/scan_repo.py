#!/usr/bin/env python3
"""Scan a git repo for secrets and live values that should be placeholders.

Prints JSON to stdout. Never prints secret values — only path, kind, line, and
a redacted reason. Exit 0 if no blocking findings, 1 otherwise.

Usage:
  python3 scan_repo.py [repo_root]
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

SKIP_DIR_NAMES = {
    ".git",
    "node_modules",
    "__pycache__",
    ".unit-out",
    "reference",
    ".venv",
    "venv",
}
SKIP_SUFFIXES = {
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".webp",
    ".ico",
    ".pdf",
    ".zip",
    ".gz",
    ".tgz",
    ".whl",
    ".pyc",
    ".svg",
}
MAX_FILE_BYTES = 1_000_000

# Intentional placeholders — allowed in tracked files.
PLACEHOLDER_RE = re.compile(
    r"CHANGE_ME_[A-Z0-9_]+|REPLACE_WITH_[A-Z0-9_]+|<base64\(|<strong-password>|"
    r"<quay-[^>]+>|<password>|<same-as-[^>]+>|<your-[^>]+>|<pat>|"
    r"YOUR_[A-Z0-9_]+|TODO_SECRET",
    re.I,
)

# Live lab / OpenShift cluster public FQDNs that must not be committed.
LIVE_FQDN_RE = re.compile(
    r"(?:[a-z0-9-]+\.)*(?:sandbox\d+\.opentlc\.com|"
    r"apps\.cluster-[a-z0-9]+\.[a-z0-9-]+\.[a-z0-9.]+|"
    r"api\.cluster-[a-z0-9]+\.[a-z0-9-]+\.[a-z0-9.]+)",
    re.I,
)

# In-cluster names are fine.
OK_HOST_RE = re.compile(
    r"\.(?:svc|svc\.cluster\.local)(?:/|:|$)|localhost|example\.com|quay\.io|"
    r"registry\.redhat\.io|ghcr\.io|github\.com",
    re.I,
)

TOKEN_RES = [
    ("github_pat", re.compile(r"\bghp_[A-Za-z0-9]{36}\b")),
    ("github_fine_grained", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("gitlab_pat", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b")),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("openai_key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9]{20,}\b")),
    ("anthropic_key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b")),
    ("aws_access_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("hf_token", re.compile(r"\bhf_[A-Za-z0-9]{20,}\b")),
    ("private_key_pem", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("kubeconfig_token", re.compile(r"\beyJhbGciOi[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b")),
]

SECRET_VALUE_LINE_RE = re.compile(
    r"(?i)^\s*(?:[-*]?\s*)?(?:password|passwd|secret|token|api[_-]?key|"
    r"aws_secret_access_key|database-password|MINIO_ROOT_PASSWORD|"
    r"AWS_SECRET_ACCESS_KEY|HF_TOKEN|GIT_TOKEN)\s*[:=]\s*(\S+)"
)

DOCKER_AUTH_RE = re.compile(r'"auth"\s*:\s*"([^"]+)"')

MUST_IGNORE_DEFAULT = (
    "quay-secret.yaml",
    "minio-s3-secret.yaml",
    ".env",
    "kubeconfig",
    "kubeconfig.yaml",
)

KNOWN_PLACEHOLDER_FILES_DEFAULT: dict[str, str] = {}

def load_patterns(repo: Path) -> tuple[tuple[str, ...], dict[str, str]]:
    must = list(MUST_IGNORE_DEFAULT)
    known = dict(KNOWN_PLACEHOLDER_FILES_DEFAULT)
    candidates = [
        Path(__file__).resolve().parent.parent / "patterns.json",
        repo / ".cursor/skills/safe-git-push/patterns.json",
    ]
    seen: set[Path] = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        if resolved in seen or not resolved.is_file():
            continue
        seen.add(resolved)
        data = json.loads(resolved.read_text(encoding="utf-8"))
        must.extend(data.get("must_ignore") or [])
        known.update(data.get("known_placeholder_files") or {})
    # Preserve order, drop dupes
    must_u = tuple(dict.fromkeys(must))
    return must_u, known


def run_git(repo: Path, args: list[str]) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True)


def tracked_files(repo: Path) -> list[str]:
    out = run_git(repo, ["ls-files", "-z"])
    return [p for p in out.split("\0") if p]


def staged_files(repo: Path) -> set[str]:
    out = run_git(repo, ["diff", "--cached", "--name-only", "-z"])
    return {p for p in out.split("\0") if p}


def is_ignored(repo: Path, rel: str) -> bool:
    r = subprocess.run(
        ["git", "-C", str(repo), "check-ignore", "-q", rel],
        capture_output=True,
    )
    return r.returncode == 0


def looks_placeholder(value: str) -> bool:
    v = value.strip().strip("'\"")
    if not v or v in {"''", '""', "null", "changeme"}:
        return True
    if PLACEHOLDER_RE.search(v):
        return True
    if v.startswith("<") and ">" in v:
        return True
    # Shell / K8s references, not a literal credential.
    if v.startswith("$") or v.startswith("`"):
        return True
    # Code expressions (e.g. token = fh.read().strip()), not a literal.
    if any(ch in value for ch in "()[]{}"):
        return True
    return False


def finding(
    *,
    path: str,
    kind: str,
    severity: str,
    reason: str,
    line: int | None = None,
    fix: str | None = None,
) -> dict:
    item = {"path": path, "kind": kind, "severity": severity, "reason": reason}
    if line is not None:
        item["line"] = line
    if fix:
        item["fix"] = fix
    return item


def scan_text(rel: str, text: str, known_placeholder_files: dict[str, str]) -> list[dict]:
    findings: list[dict] = []
    for i, line in enumerate(text.splitlines(), 1):
        if LIVE_FQDN_RE.search(line) and not OK_HOST_RE.search(line):
            findings.append(
                finding(
                    path=rel,
                    kind="live_cluster_fqdn",
                    severity="block",
                    reason="Live lab/cluster FQDN in tracked file; replace with REPLACE_WITH_CLUSTER_APPS_DOMAIN",
                    line=i,
                    fix="replace_fqdn",
                )
            )
        for kind, cre in TOKEN_RES:
            if cre.search(line) and not looks_placeholder(line):
                findings.append(
                    finding(
                        path=rel,
                        kind=kind,
                        severity="block",
                        reason="Credential-shaped token in tracked file (value omitted)",
                        line=i,
                    )
                )
        m = SECRET_VALUE_LINE_RE.search(line)
        if m and not looks_placeholder(m.group(1)):
            # Skip comments that only mention the key name with no assignment of a live value
            stripped = line.lstrip()
            if stripped.startswith("#") and PLACEHOLDER_RE.search(line):
                continue
            if stripped.startswith("#") and ("<" in line or "changeme" in line.lower()):
                continue
            # Comments documenting how to set secrets are OK if they use placeholders.
            if stripped.startswith("#"):
                continue
            findings.append(
                finding(
                    path=rel,
                    kind="live_secret_value",
                    severity="block",
                    reason="Non-placeholder secret/password/token assignment (value omitted)",
                    line=i,
                    fix="restore_placeholder",
                )
            )
        for am in DOCKER_AUTH_RE.finditer(line):
            if not looks_placeholder(am.group(1)):
                findings.append(
                    finding(
                        path=rel,
                        kind="dockerconfig_auth",
                        severity="block",
                        reason="dockerconfigjson auth is filled in, not a placeholder (value omitted)",
                        line=i,
                        fix="restore_placeholder",
                    )
                )
    expected = known_placeholder_files.get(rel.replace("\\", "/"))
    if expected and expected not in text:
        findings.append(
            finding(
                path=rel,
                kind="missing_expected_placeholder",
                severity="block",
                reason=f"Expected placeholder {expected} is missing from this file",
                fix="restore_placeholder",
            )
        )
    return findings


def should_skip_file(path: Path) -> bool:
    if any(part in SKIP_DIR_NAMES for part in path.parts):
        return True
    if path.suffix.lower() in SKIP_SUFFIXES:
        return True
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return True
    except OSError:
        return True
    return False


def main() -> int:
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else os.getcwd()).resolve()
    must_ignore, known_placeholder_files = load_patterns(repo)
    blocking: list[dict] = []
    info: list[dict] = []
    placeholder_ok: list[dict] = []

    tracked = tracked_files(repo)
    staged = staged_files(repo)

    for name in must_ignore:
        p = repo / name
        if not p.exists():
            continue
        ignored = is_ignored(repo, name)
        tracked_hit = name in tracked
        staged_hit = name in staged
        if tracked_hit or staged_hit:
            blocking.append(
                finding(
                    path=name,
                    kind="secret_file_tracked",
                    severity="block",
                    reason="Local secret file is tracked or staged; unstage and keep gitignored",
                    fix="unstage_and_gitignore",
                )
            )
        elif ignored:
            info.append(
                finding(
                    path=name,
                    kind="local_secret_ignored",
                    severity="info",
                    reason="Local secret file is gitignored (do not git add -f)",
                )
            )
        else:
            blocking.append(
                finding(
                    path=name,
                    kind="secret_file_not_ignored",
                    severity="block",
                    reason="Local secret file exists and is not gitignored",
                    fix="gitignore",
                )
            )

    for rel in tracked:
        path = repo / rel
        if should_skip_file(path) or not path.is_file():
            continue
        try:
            raw = path.read_bytes()
        except OSError:
            continue
        if b"\0" in raw[:8000]:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        hits = scan_text(rel, text, known_placeholder_files)
        blocking.extend(h for h in hits if h["severity"] == "block")
        if PLACEHOLDER_RE.search(text) and rel.replace("\\", "/") in known_placeholder_files:
            placeholder_ok.append(
                finding(
                    path=rel,
                    kind="placeholder_ok",
                    severity="info",
                    reason="Tracked file still uses the expected placeholder token",
                )
            )

    # Staged-but-not-yet-committed extra files
    for rel in staged:
        if rel in tracked:
            continue
        path = repo / rel
        if should_skip_file(path) or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        blocking.extend(scan_text(rel, text, known_placeholder_files))

    report = {
        "ok": not blocking,
        "blocking": blocking,
        "info": info,
        "placeholder_ok": placeholder_ok,
    }
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
