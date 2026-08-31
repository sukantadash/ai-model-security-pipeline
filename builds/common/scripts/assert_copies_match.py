#!/usr/bin/env python3
"""Fail if image/kustomize copies drifted from canonical sources.

OpenShift binary builds use --from-dir=builds/<image>, so vllm_client.py and
s3-common.sh must live inside each image context. Kustomize ConfigMaps cannot
read files outside instances/tekton-tasks/, so register_model.py is copied there.

Do not delete those copies. Keep them byte-identical to the canonical file.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

PAIRS: list[tuple[str, list[str]]] = [
    (
        "builds/common/scripts/vllm_client.py",
        [
            "builds/dynamic-test/scripts/vllm_client.py",
            "builds/capability-eval/scripts/vllm_client.py",
            "builds/adversarial-test/scripts/vllm_client.py",
        ],
    ),
    (
        "builds/common/scripts/s3-common.sh",
        [
            "builds/model-fetch/scripts/s3-common.sh",
            "builds/publish/scripts/s3-common.sh",
        ],
    ),
    (
        "builds/publish/scripts/register_model.py",
        ["instances/tekton-tasks/register_model.py"],
    ),
]


def main() -> int:
    failed = 0
    for canonical_rel, copies in PAIRS:
        canonical = ROOT / canonical_rel
        src = canonical.read_bytes()
        for copy_rel in copies:
            copy = ROOT / copy_rel
            if not copy.is_file():
                print(f"missing copy: {copy_rel}", file=sys.stderr)
                failed += 1
                continue
            if copy.read_bytes() != src:
                print(f"drift: {copy_rel} != {canonical_rel}", file=sys.stderr)
                failed += 1
    if failed:
        print(f"{failed} copy check(s) failed", file=sys.stderr)
        return 1
    print("ok: image/kustomize copies match canonical sources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
