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

    def test_named_dns_port_does_not_crash_or_flag_https(self) -> None:
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
                                            "to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "openshift-dns"}}}],
                                            "ports": [{"port": "dns", "protocol": "UDP"}, {"port": "dns-tcp", "protocol": "TCP"}],
                                        },
                                        {
                                            "to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "minio-system"}}}],
                                            "ports": [{"port": 9000}],
                                        },
                                    ]
                                },
                            }
                        ]
                    }
                )
            )
            findings = run_inspect(d)
            self.assertFalse(any(f.get("tool_used") == "networkpolicy" and f.get("risk") == "critical" for f in findings), findings)
            self.assertFalse(any("invalid literal" in (f.get("issue") or "") for f in findings))


class BehaviorInspectTest(unittest.TestCase):
    def test_startup_probe_unhealthy_is_not_high(self) -> None:
        script = ROOT / "run-behavior.sh"
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "events.json").write_text(
                json.dumps(
                    {
                        "items": [
                            {
                                "reason": "Unhealthy",
                                "message": 'Startup probe failed: Get "https://10.0.0.1:8000/health": connection refused',
                            },
                            {"reason": "FailedScheduling", "message": "0/3 nodes available"},
                        ]
                    }
                )
            )
            out = d / "out.json"
            env = os.environ.copy()
            env["SANDBOX_INSPECT_DIR"] = str(d)
            subprocess.run(["bash", str(script), str(out)], check=True, env=env, capture_output=True)
            findings = json.loads(out.read_text())
            self.assertFalse(any(f.get("risk") in ("high", "critical") for f in findings), findings)

    def test_killing_event_is_not_high(self) -> None:
        script = ROOT / "run-behavior.sh"
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "pods.json").write_text(json.dumps({"items": [{"metadata": {"name": "eval-x-kserve-abc"}}]}))
            (d / "events.json").write_text(
                json.dumps(
                    {
                        "items": [
                            {
                                "reason": "Killing",
                                "message": "Stopping container main",
                                "involvedObject": {"name": "eval-x-kserve-abc"},
                            }
                        ]
                    }
                )
            )
            out = d / "out.json"
            env = os.environ.copy()
            env["SANDBOX_INSPECT_DIR"] = str(d)
            subprocess.run(["bash", str(script), str(out)], check=True, env=env, capture_output=True)
            findings = json.loads(out.read_text())
            self.assertFalse(any(f.get("risk") in ("high", "critical") for f in findings), findings)

    def test_oomkilled_is_high(self) -> None:
        script = ROOT / "run-behavior.sh"
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "events.json").write_text(json.dumps({"items": [{"reason": "OOMKilled", "message": "container killed"}]}))
            out = d / "out.json"
            env = os.environ.copy()
            env["SANDBOX_INSPECT_DIR"] = str(d)
            subprocess.run(["bash", str(script), str(out)], check=True, env=env, capture_output=True)
            findings = json.loads(out.read_text())
            self.assertTrue(any(f.get("risk") == "high" and "OOMKilled" in (f.get("issue") or "") for f in findings), findings)


if __name__ == "__main__":
    unittest.main()
