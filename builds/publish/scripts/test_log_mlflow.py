#!/usr/bin/env python3
"""Unit tests for log_mlflow.py metric extraction (no MLflow server needed).

    cd builds/publish/scripts && python3 -m unittest -q test_log_mlflow
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import log_mlflow as lm


def write(d: Path, name: str, obj) -> None:
    (d / name).write_text(json.dumps(obj))


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        write(self.dir, "score.json", {"passed": False, "routing": "review", "S_total": 55.0,
                                       "S_static": 50.0, "S_capability": 100.0, "S_redteam": 0.0})
        write(self.dir, "adversarial-test.json", [
            {"issue": "prompt injection ASR 1.00 exceeded ceiling 0.10", "risk": "critical", "tool_used": "garak"},
            {"issue": "jailbreak / guardrail bypass rate 0.50 exceeded ceiling 0.05", "risk": "high"},
            {"issue": "nemo guardrails false-positive rate 0.33", "risk": "medium", "tool_used": "nemo-guardrails"},
        ])
        write(self.dir, "adversarial-nemo-guardrails.json",
              [{"issue": "nemo guardrails false-positive rate 0.33", "risk": "medium", "tool_used": "nemo-guardrails"}])
        write(self.dir, "static-scan.json", {"issues": [{"issue": "license unlisted", "risk": "medium"}]})
        write(self.dir, "nemo-guardrails-summary.json", {"attacks": 8, "attacks_blocked": 6, "benign": 3,
                                                         "benign_blocked": 1, "errors": 1, "answered": 4,
                                                         "thinking_replies": 2})
        write(self.dir, "publish.json", {"modelcar_image": "quay.io/a/r:redhatai-x-verified-55-abc12"})

    def test_metrics_and_tags(self):
        score, m, tags = lm.collect(self.dir)
        self.assertEqual(m["S_total"], 55.0)
        self.assertEqual(m["passed"], 0.0)
        self.assertEqual(m["findings_redteam_critical"], 1.0)
        self.assertEqual(m["findings_redteam_high"], 1.0)
        self.assertEqual(m["findings_redteam_medium"], 0.0)          # NeMo row excluded from red team
        self.assertEqual(m["findings_guardrails_medium"], 1.0)
        self.assertEqual(m["findings_static_medium"], 1.0)
        self.assertEqual(m["findings_dynamic_critical"], 0.0)       # missing file → zeros
        self.assertEqual(m["findings_total"], 4.0)
        self.assertEqual(m["unguarded_prompt_injection_rate"], 1.0)
        self.assertEqual(m["unguarded_jailbreak_rate"], 0.5)
        self.assertEqual(m["unguarded_harmful_content_exceeded"], 0.0)
        self.assertNotIn("unguarded_harmful_content_rate", m)
        self.assertEqual(m["guardrails_attack_block_rate"], 0.75)
        self.assertAlmostEqual(m["guardrails_false_positive_rate"], 1 / 3)
        self.assertEqual(m["guardrails_thinking_rate"], 0.5)
        self.assertEqual(tags["routing"], "review")
        self.assertEqual(tags["published_tag"], "redhatai-x-verified-55-abc12")

    def test_skip_without_uri(self):
        with mock.patch.dict(os.environ, {"MLFLOW_TRACKING_URI": ""}):
            self.assertEqual(lm.main(), 0)

    def test_never_fails_on_bad_inputs(self):
        with mock.patch.dict(os.environ, {"MLFLOW_TRACKING_URI": "http://127.0.0.1:1", "RESULTS_DIR": "/nonexistent",
                                          "MODEL_ID": "", "PIPELINE_RUN": ""}):
            self.assertEqual(lm.main(), 0)


if __name__ == "__main__":
    unittest.main()
