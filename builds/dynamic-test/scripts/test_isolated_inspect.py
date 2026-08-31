#!/usr/bin/env python3
"""Inspect-mode tests for isolated-runtime (sandbox serving pod, not Task pod)."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "run-isolated-runtime.sh"


def run_inspect(inspect_dir: Path) -> list:
    out = inspect_dir / "out.json"
    env = os.environ.copy()
    env["SANDBOX_INSPECT_DIR"] = str(inspect_dir)
    subprocess.run(["bash", str(SCRIPT), str(out)], check=True, env=env, capture_output=True)
    return json.loads(out.read_text())


class IsolatedInspectTest(unittest.TestCase):
    def test_open_egress_is_critical(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "llmis.json").write_text(json.dumps({"kind": "LLMInferenceService", "metadata": {"name": "eval-x"}}))
            (d / "pods.json").write_text(json.dumps({"items": [{"spec": {"runtimeClassName": ""}}]}))
            (d / "networkpolicies.json").write_text(
                json.dumps(
                    {
                        "items": [
                            {
                                "metadata": {"name": "wide-open"},
                                "spec": {
                                    "egress": [
                                        {"to": [{"ipBlock": {"cidr": "0.0.0.0/0"}}], "ports": [{"port": 443}]}
                                    ]
                                },
                            }
                        ]
                    }
                )
            )
            findings = run_inspect(d)
            risks = {(f.get("tool_used"), f.get("risk")) for f in findings}
            self.assertIn(("networkpolicy", "critical"), risks)

    def test_tight_np_kata_optional_medium(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "llmis.json").write_text(json.dumps({"kind": "LLMInferenceService", "metadata": {"name": "eval-x"}}))
            (d / "pods.json").write_text(json.dumps({"items": [{"spec": {}}]}))
            (d / "networkpolicies.json").write_text(
                json.dumps(
                    {
                        "items": [
                            {
                                "metadata": {"name": "dns-minio"},
                                "spec": {
                                    "egress": [
                                        {
                                            "to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "minio-system"}}}],
                                            "ports": [{"port": 9000}],
                                        }
                                    ]
                                },
                            }
                        ]
                    }
                )
            )
            findings = run_inspect(d)
            self.assertFalse(any(f.get("risk") == "critical" for f in findings))
            self.assertTrue(any(f.get("tool_used") == "kata-runtimeclass" and f.get("risk") == "medium" for f in findings))


if __name__ == "__main__":
    unittest.main()
