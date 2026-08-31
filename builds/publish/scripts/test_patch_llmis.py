#!/usr/bin/env python3
"""Unit tests for patch_llmis.py (no cluster)."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from patch_llmis import find_llmis_files, patch_path


SAMPLE = """
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: PLACEHOLDER
  namespace: model-sandbox
  annotations:
    openshift.io/display-name: PLACEHOLDER
spec:
  model:
    uri: s3://models-ingress/PLACEHOLDER/
    name: PLACEHOLDER
"""


class PatchLlmisTest(unittest.TestCase):
    def test_patch_name_and_uri(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "LLMInferenceService.yaml"
            dest = Path(tmp) / "out.yaml"
            src.write_text(SAMPLE)
            n = patch_path(
                src,
                dest,
                name="eval-abcde",
                model_name="redhatai-qwen3-8b-fp8-dynamic",
                model_uri="s3://models-ingress/redhatai-qwen3-8b-fp8-dynamic/",
                namespace="model-sandbox",
            )
            self.assertEqual(n, 1)
            doc = yaml.safe_load(dest.read_text())
            self.assertEqual(doc["metadata"]["name"], "eval-abcde")
            self.assertEqual(doc["spec"]["model"]["name"], "redhatai-qwen3-8b-fp8-dynamic")
            self.assertEqual(
                doc["spec"]["model"]["uri"],
                "s3://models-ingress/redhatai-qwen3-8b-fp8-dynamic/",
            )
            self.assertEqual(doc["metadata"]["annotations"]["openshift.io/display-name"], "eval-abcde")

    def test_find_under_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "LLMInferenceService.yaml").write_text(SAMPLE)
            (root / "networkpolicy.yaml").write_text("kind: NetworkPolicy\nmetadata:\n  name: x\n")
            found = find_llmis_files(root)
            self.assertEqual([p.name for p in found], ["LLMInferenceService.yaml"])


if __name__ == "__main__":
    unittest.main()
