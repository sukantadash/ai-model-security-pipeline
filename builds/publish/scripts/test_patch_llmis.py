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
                "s3://models-ingress/redhatai-qwen3-8b-fp8-dynamic",
            )
            self.assertEqual(doc["metadata"]["annotations"]["openshift.io/display-name"], "eval-abcde")

    def test_uri_only_keeps_template_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "qwen.yaml"
            dest = Path(tmp) / "out.yaml"
            src.write_text(
                """
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen3-8b-fp8
  annotations:
    openshift.io/display-name: qwen3-8b-fp8-verified
    security.platform/model-version: PLACEHOLDER
spec:
  model:
    uri: s3://models-verified/redhatai-qwen3-8b-fp8-dynamic/PLACEHOLDER
    name: redhatai-qwen3-8b-fp8-dynamic
"""
            )
            n = patch_path(
                src,
                dest,
                name=None,
                model_name=None,
                model_uri="s3://models-verified/redhatai-qwen3-8b-fp8-dynamic/9djp2",
                namespace="model-test",
                model_version="9djp2",
                registered_model="redhatai-qwen3-8b-fp8-dynamic",
            )
            self.assertEqual(n, 1)
            doc = yaml.safe_load(dest.read_text())
            self.assertEqual(doc["metadata"]["name"], "qwen3-8b-fp8")
            self.assertEqual(doc["spec"]["model"]["name"], "redhatai-qwen3-8b-fp8-dynamic")
            self.assertEqual(
                doc["spec"]["model"]["uri"],
                "s3://models-verified/redhatai-qwen3-8b-fp8-dynamic/9djp2",
            )
            self.assertEqual(doc["metadata"]["namespace"], "model-test")
            self.assertEqual(
                doc["metadata"]["annotations"]["openshift.io/display-name"],
                "redhatai-qwen3-8b-fp8-dynamic - 9djp2",
            )
            self.assertEqual(doc["metadata"]["annotations"]["security.platform/model-version"], "9djp2")
            self.assertEqual(
                doc["metadata"]["annotations"]["opendatahub.io/connection-path"],
                "redhatai-qwen3-8b-fp8-dynamic/9djp2",
            )
            self.assertEqual(
                doc["metadata"]["annotations"]["opendatahub.io/connections"],
                "redhatai-qwen3-8b-fp8-dynamic-9djp2",
            )

    def test_find_under_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "LLMInferenceService.yaml").write_text(SAMPLE)
            (root / "networkpolicy.yaml").write_text("kind: NetworkPolicy\nmetadata:\n  name: x\n")
            found = find_llmis_files(root)
            self.assertEqual([p.name for p in found], ["LLMInferenceService.yaml"])


if __name__ == "__main__":
    unittest.main()
