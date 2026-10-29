#!/usr/bin/env python3
"""Unit tests for patch_llmis.py (no cluster)."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from patch_llmis import llmis_name, patch_path


SAMPLE = """
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: eval-sandbox
  namespace: model-sandbox
spec:
  model:
    uri: oci://PLACEHOLDER
    name: redhatai-qwen3-8b-fp8-dynamic
"""


class PatchLlmisTest(unittest.TestCase):
    def test_uri_only_keeps_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "LLMInferenceService.yaml"
            dest = Path(tmp) / "out.yaml"
            src.write_text(SAMPLE)
            n = patch_path(
                src,
                dest,
                model_uri="oci://quay.io/sudash/ai-model-security-pipeline:redhatai-qwen3-8b-fp8-dynamic-unverified",
                namespace="model-sandbox",
            )
            self.assertEqual(n, 1)
            doc = yaml.safe_load(dest.read_text())
            self.assertEqual(doc["metadata"]["name"], "eval-sandbox")
            self.assertEqual(doc["spec"]["model"]["name"], "redhatai-qwen3-8b-fp8-dynamic")
            self.assertEqual(
                doc["spec"]["model"]["uri"],
                "oci://quay.io/sudash/ai-model-security-pipeline:redhatai-qwen3-8b-fp8-dynamic-unverified",
            )
            self.assertEqual(doc["metadata"]["namespace"], "model-sandbox")

    def test_verified_uri_replace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "qwen3-8b-fp8-verified.yaml"
            dest = Path(tmp) / "out.yaml"
            src.write_text(
                """
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: qwen3-8b-fp8
spec:
  model:
    uri: oci://PLACEHOLDER
    name: redhatai-qwen3-8b-fp8-dynamic
"""
            )
            n = patch_path(
                src,
                dest,
                model_uri="oci://quay.io/sudash/ai-model-security-pipeline:redhatai-qwen3-8b-fp8-dynamic-verified-87-9djp2",
            )
            self.assertEqual(n, 1)
            doc = yaml.safe_load(dest.read_text())
            self.assertEqual(doc["metadata"]["name"], "qwen3-8b-fp8")
            self.assertEqual(
                doc["spec"]["model"]["uri"],
                "oci://quay.io/sudash/ai-model-security-pipeline:redhatai-qwen3-8b-fp8-dynamic-verified-87-9djp2",
            )

    def test_llmis_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "svc.yaml"
            src.write_text(SAMPLE)
            self.assertEqual(llmis_name(src), "eval-sandbox")

    def test_requires_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "missing.yaml"
            dest = Path(tmp) / "out.yaml"
            with self.assertRaises(FileNotFoundError):
                patch_path(src, dest, model_uri="oci://x:unverified")


if __name__ == "__main__":
    unittest.main()
