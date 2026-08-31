#!/usr/bin/env python3
"""Register a verified model in RHOAI Model Registry (v1alpha3 REST).

Canonical: builds/publish/scripts/register_model.py
Task ConfigMap: instances/tekton-tasks/register_model.py
Keep these two files identical (kustomize cannot read files outside tekton-tasks/).

Talks to kube-rbac-proxy on :8443 with the TaskRun ServiceAccount token.
Creates RegisteredModel + ModelVersion + ModelArtifact (idempotent on name).
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


def _str_prop(value: str) -> dict:
    return {"metadataType": "MetadataStringValue", "string_value": value}


def _request(url: str, token: str, method: str, path: str, body: dict | None = None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url.rstrip("/") + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            raw = resp.read()
            parsed = json.loads(raw) if raw else {}
            return resp.status, parsed
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            parsed = {"body": raw.decode(errors="replace")}
        return exc.code, parsed
    except Exception as exc:
        return 0, {"error": str(exc)}


def _require(code: int, body: dict, ok: tuple[int, ...], what: str) -> dict:
    if code not in ok:
        raise SystemExit(f"{what} returned {code}: {json.dumps(body, indent=2)}")
    return body


def main() -> int:
    mr_url = os.environ["MR_URL"]
    token_path = os.environ.get(
        "SA_TOKEN_PATH", "/var/run/secrets/kubernetes.io/serviceaccount/token"
    )
    with open(token_path, encoding="utf-8") as fh:
        token = fh.read().strip()
    if not token:
        raise SystemExit("empty service account token; cannot authenticate to Model Registry")

    model_id = os.environ["MODEL_ID"]
    version = os.environ["VERSION"]
    s3_uri = os.environ["S3_URI"]
    scan_uri = os.environ["SCAN_URI"]
    routing = os.environ["ROUTING"]
    props = {
        "storage_uri": _str_prop(s3_uri),
        "scan_uri": _str_prop(scan_uri),
        "version": _str_prop(version),
        "routing": _str_prop(routing),
    }

    def req(method: str, path: str, body: dict | None = None):
        code, parsed = _request(mr_url, token, method, path, body)
        print(f"Model Registry {method} {path} -> {code}", file=sys.stderr)
        return code, parsed

    q = urllib.parse.urlencode({"name": model_id})
    code, body = req("GET", f"/api/model_registry/v1alpha3/registered_model?{q}")
    if code == 200 and body.get("id"):
        rm_id = str(body["id"])
        print(f"Reusing RegisteredModel id={rm_id}", file=sys.stderr)
    else:
        code, body = req(
            "POST",
            "/api/model_registry/v1alpha3/registered_models",
            {
                "name": model_id,
                "description": f"Published by model-security-pipeline ({routing})",
                "customProperties": props,
            },
        )
        if code == 409:
            code, body = req("GET", f"/api/model_registry/v1alpha3/registered_model?{q}")
            _require(code, body, (200,), "find registered_model after conflict")
        else:
            _require(code, body, (200, 201), "create registered_model")
        rm_id = str(body["id"])

    code, body = req(
        "POST",
        f"/api/model_registry/v1alpha3/registered_models/{rm_id}/versions",
        {
            "name": version,
            "registeredModelId": rm_id,
            "description": f"Pipeline version {version} ({routing})",
            "customProperties": props,
        },
    )
    if code == 409:
        code, listing = req(
            "GET", f"/api/model_registry/v1alpha3/registered_models/{rm_id}/versions"
        )
        _require(code, listing, (200,), "list model versions after conflict")
        match = next(
            (item for item in listing.get("items") or [] if item.get("name") == version),
            None,
        )
        if not match:
            raise SystemExit(f"version {version} conflicted but was not listed: {listing}")
        mv_id = str(match["id"])
        print(f"Reusing ModelVersion id={mv_id}", file=sys.stderr)
    else:
        _require(code, body, (200, 201), "create model version")
        mv_id = str(body["id"])

    artifact_name = f"{model_id}-{version}"
    code, body = req(
        "POST",
        f"/api/model_registry/v1alpha3/model_versions/{mv_id}/artifacts",
        {
            "artifactType": "model-artifact",
            "name": artifact_name,
            "uri": s3_uri,
            "modelFormatName": "safetensors",
            "customProperties": props,
        },
    )
    if code == 409:
        print("ModelArtifact already exists; continuing", file=sys.stderr)
    else:
        _require(code, body, (200, 201), "create model artifact")

    print(
        json.dumps(
            {
                "registered_model_id": rm_id,
                "model_version_id": mv_id,
                "uri": s3_uri,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
