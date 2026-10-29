#!/usr/bin/env python3
"""Replace placeholder image URI in an LLMInferenceService YAML file.

Only updates spec.model.uri. Callers own metadata.name and all other fields.
Expects a single file path (not a directory of templates).
"""
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


def patch_doc(doc: dict, *, model_uri: str, namespace: str | None = None) -> dict:
    out = copy.deepcopy(doc)
    if namespace:
        out.setdefault("metadata", {})["namespace"] = namespace
    spec = out.setdefault("spec", {})
    model = spec.setdefault("model", {})
    model["uri"] = model_uri.rstrip("/")
    return out


def patch_path(
    src: Path,
    dest: Path,
    *,
    model_uri: str,
    namespace: str | None = None,
) -> int:
    docs = load_docs(src)
    patched = 0
    out_docs = []
    for doc in docs:
        if is_llmis(doc):
            out_docs.append(patch_doc(doc, model_uri=model_uri, namespace=namespace))
            patched += 1
        else:
            out_docs.append(doc)
    if patched == 0:
        raise SystemExit(f"no LLMInferenceService in {src}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w") as fh:
        yaml.safe_dump_all(out_docs, fh, sort_keys=False)
    return patched


def llmis_name(src: Path) -> str:
    for doc in load_docs(src):
        if is_llmis(doc):
            name = (doc.get("metadata") or {}).get("name")
            if name:
                return str(name)
    raise SystemExit(f"LLMInferenceService missing metadata.name in {src}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("src", help="Path to LLMInferenceService YAML file")
    p.add_argument("--out-dir", default="", help="Directory to write patched YAML")
    p.add_argument("--model-uri", default="", help="Replacement for spec.model.uri")
    p.add_argument("--namespace", default="", help="Optional metadata.namespace override")
    p.add_argument(
        "--print-name",
        action="store_true",
        help="Print metadata.name of the first LLMInferenceService to stdout and exit",
    )
    args = p.parse_args()
    src = Path(args.src)
    if not src.is_file():
        print(f"serving YAML must be a file: {src}", file=sys.stderr)
        return 1
    if args.print_name:
        print(llmis_name(src), end="")
        return 0
    if not args.out_dir or not args.model_uri:
        print("--out-dir and --model-uri are required unless --print-name", file=sys.stderr)
        return 2
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / src.name
    n = patch_path(
        src,
        dest,
        model_uri=args.model_uri,
        namespace=args.namespace or None,
    )
    print(f"patched {src} -> {dest} ({n} LLMInferenceService)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
