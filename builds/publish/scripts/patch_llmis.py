#!/usr/bin/env python3
"""Patch LLMInferenceService YAML: metadata.name, spec.model.name, spec.model.uri."""
from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is required (pip install pyyaml)", file=sys.stderr)
    raise SystemExit(2)


def load_docs(path: Path) -> list:
    text = path.read_text()
    docs = list(yaml.safe_load_all(text))
    return [d for d in docs if d is not None]


def is_llmis(doc: dict) -> bool:
    return isinstance(doc, dict) and str(doc.get("kind") or "") == "LLMInferenceService"


def patch_doc(doc: dict, *, name: str, model_name: str, model_uri: str, namespace: str | None) -> dict:
    out = copy.deepcopy(doc)
    meta = out.setdefault("metadata", {})
    meta["name"] = name
    if namespace:
        meta["namespace"] = namespace
    ann = meta.setdefault("annotations", {})
    if "openshift.io/display-name" in ann:
        ann["openshift.io/display-name"] = name
    spec = out.setdefault("spec", {})
    model = spec.setdefault("model", {})
    model["name"] = model_name
    model["uri"] = model_uri
    return out


def find_llmis_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    found = []
    for path in sorted(root.rglob("*")):
        if path.suffix.lower() not in {".yaml", ".yml"}:
            continue
        if path.name == "kustomization.yaml":
            continue
        try:
            docs = load_docs(path)
        except yaml.YAMLError:
            continue
        if any(is_llmis(d) for d in docs):
            found.append(path)
    return found


def patch_path(src: Path, dest: Path, *, name: str, model_name: str, model_uri: str, namespace: str | None) -> int:
    docs = load_docs(src)
    patched = 0
    out_docs = []
    for doc in docs:
        if is_llmis(doc):
            out_docs.append(
                patch_doc(doc, name=name, model_name=model_name, model_uri=model_uri, namespace=namespace)
            )
            patched += 1
        else:
            out_docs.append(doc)
    if patched == 0:
        raise SystemExit(f"no LLMInferenceService in {src}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w") as fh:
        yaml.safe_dump_all(out_docs, fh, sort_keys=False)
    return patched


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("src", help="File or directory containing LLMInferenceService YAML")
    p.add_argument("--out-dir", required=True, help="Directory to write patched YAML")
    p.add_argument("--name", required=True, help="metadata.name")
    p.add_argument("--model-name", required=True, help="spec.model.name")
    p.add_argument("--model-uri", required=True, help="spec.model.uri")
    p.add_argument("--namespace", default="", help="metadata.namespace (optional)")
    args = p.parse_args()
    src = Path(args.src)
    if not src.exists():
        print(f"path not found: {src}", file=sys.stderr)
        return 1
    files = find_llmis_files(src)
    if not files:
        print(f"no LLMInferenceService YAML under {src}", file=sys.stderr)
        return 1
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    ns = args.namespace or None
    total = 0
    for path in files:
        dest = out_dir / path.name
        total += patch_path(
            path, dest, name=args.name, model_name=args.model_name, model_uri=args.model_uri, namespace=ns
        )
        print(f"patched {path} -> {dest}")
    print(f"patched {total} LLMInferenceService document(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
