#!/usr/bin/env python3
"""Download HF weights into /models for a ModelCar build stage."""
from __future__ import annotations

import os

from huggingface_hub import snapshot_download

model_repo = os.environ.get("HF_REPO", "RedHatAI/Qwen3-8B-FP8-dynamic")
token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or None

patterns = ["*.safetensors", "*.json", "*.txt", "*.model", "*.tiktoken"]
# HF_EXTRA_PATTERNS: comma-separated additions, e.g. "*.jinja" for chat_template.jinja
patterns += [p.strip() for p in os.environ.get("HF_EXTRA_PATTERNS", "").split(",") if p.strip()]
print(f"Downloading {model_repo} with patterns {patterns}")

snapshot_download(
    repo_id=model_repo,
    local_dir="/models",
    token=token,
    allow_patterns=patterns,
)
