#!/usr/bin/env python3
"""Log one PipelineRun's results to MLflow (RHOAI MLflow, workspace = pod namespace).

Called by Task archive-results (step log-mlflow) after the scan results are downloaded.
Never fails the pipeline: any problem is printed as a warning and the script exits 0.

One MLflow run per PipelineRun, in experiment MLFLOW_EXPERIMENT (default
"ai-model-security-pipeline"). Re-running for the same PipelineRun updates that run.

  params    model_id, version, modelcar_image, git_url, git_revision
  tags      pipeline_run, model_id, routing, published_tag, passed
  metrics   S_total, S_static, S_capability, S_redteam, passed
            findings_total, findings_<stage>_<risk>        (stage: static, dynamic, capability,
                                                            redteam, guardrails)
            unguarded_<attack>_rate, unguarded_<attack>_exceeded   (only when reported)
            guardrails_attack_block_rate, guardrails_false_positive_rate,
            guardrails_errors, guardrails_thinking_rate     (from nemo-guardrails-summary.json)
  artifacts every *.json in RESULTS_DIR under scan-result/

Env: MLFLOW_TRACKING_URI (empty = skip), MODEL_ID, PIPELINE_RUN, VERSION, RESULTS_DIR,
     MODELCAR_IMAGE, GIT_URL, GIT_REVISION, MLFLOW_EXPERIMENT,
     MLFLOW_TRACKING_AUTH (kubernetes-namespaced in-cluster), REQUESTS_CA_BUNDLE.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

RISKS = ("critical", "high", "medium", "low")
STAGES = (
    ("static", "static-scan.json"),
    ("dynamic", "dynamic-scan.json"),
    ("capability", "capability.json"),
    ("redteam", "adversarial-test.json"),
    ("guardrails", "adversarial-nemo-guardrails.json"),
)
NEMO_TOOL = "nemo-guardrails"
UNGUARDED = (
    ("prompt_injection", re.compile(r"prompt injection ASR ([0-9.]+) exceeded", re.I)),
    ("jailbreak", re.compile(r"jailbreak / guardrail bypass rate ([0-9.]+) exceeded", re.I)),
    ("harmful_content", re.compile(r"harmful content rate ([0-9.]+) exceeded", re.I)),
)


def warn(msg: str) -> None:
    print(f"[log-mlflow] WARNING: {msg}", file=sys.stderr)


def load(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def issues_from(doc) -> list:
    """Same rules as score-gate aggregate-results.py."""
    if isinstance(doc, list):
        return [r for r in doc if isinstance(r, dict)]
    if isinstance(doc, dict):
        if isinstance(doc.get("issues"), list):
            return [r for r in doc["issues"] if isinstance(r, dict)]
        if "issue" in doc:
            return [doc]
    return []


def tool_of(row: dict) -> str:
    return str(row.get("tool") or row.get("tool_used") or "").lower()


def risk_of(row: dict) -> str:
    r = str(row.get("risk") or "").lower()
    return r if r in RISKS else "low"


def collect(results: Path) -> tuple[dict, dict, dict]:
    """(params-like info, metrics, tags) from a scan-result directory."""
    metrics: dict[str, float] = {}
    tags: dict[str, str] = {}
    score = load(results / "score.json") or {}
    for key in ("S_total", "S_static", "S_capability", "S_redteam"):
        if isinstance(score.get(key), (int, float)):
            metrics[key] = float(score[key])
    if "passed" in score:
        metrics["passed"] = 1.0 if score.get("passed") else 0.0
        tags["passed"] = str(bool(score.get("passed"))).lower()
    if score.get("routing"):
        tags["routing"] = str(score["routing"])

    total = 0
    redteam_texts = []
    for stage, fname in STAGES:
        rows = issues_from(load(results / fname))
        if stage == "redteam":
            rows = [r for r in rows if tool_of(r) != NEMO_TOOL]
            redteam_texts = [str(r.get("issue") or "") for r in rows]
        for risk in RISKS:
            metrics[f"findings_{stage}_{risk}"] = float(sum(1 for r in rows if risk_of(r) == risk))
        total += len(rows)
    metrics["findings_total"] = float(total)

    for name, rx in UNGUARDED:
        hit = next((m for m in (rx.search(t) for t in redteam_texts) if m), None)
        metrics[f"unguarded_{name}_exceeded"] = 1.0 if hit else 0.0
        if hit:
            metrics[f"unguarded_{name}_rate"] = float(hit.group(1))

    summary = load(results / "nemo-guardrails-summary.json")
    if isinstance(summary, dict):
        if summary.get("attacks"):
            metrics["guardrails_attack_block_rate"] = summary.get("attacks_blocked", 0) / summary["attacks"]
        if summary.get("benign"):
            metrics["guardrails_false_positive_rate"] = summary.get("benign_blocked", 0) / summary["benign"]
        metrics["guardrails_errors"] = float(summary.get("errors", 0))
        if summary.get("answered"):
            metrics["guardrails_thinking_rate"] = summary.get("thinking_replies", 0) / summary["answered"]

    publish = load(results / "publish.json") or {}
    image = str(publish.get("modelcar_image") or publish.get("published_uri") or "")
    if ":" in image:
        tags["published_tag"] = image.rsplit(":", 1)[-1]
    return score, metrics, tags


def main() -> int:
    uri = os.environ.get("MLFLOW_TRACKING_URI", "").strip()
    if not uri:
        print("[log-mlflow] MLFLOW_TRACKING_URI not set; skipping MLflow logging")
        return 0
    results = Path(os.environ.get("RESULTS_DIR", "/tmp/scan-result"))
    model_id = os.environ.get("MODEL_ID", "")
    run_name = os.environ.get("PIPELINE_RUN", "")
    version = os.environ.get("VERSION", run_name[-5:])
    experiment = os.environ.get("MLFLOW_EXPERIMENT", "ai-model-security-pipeline")
    if not results.is_dir() or not model_id or not run_name:
        warn(f"missing inputs (RESULTS_DIR={results}, MODEL_ID={model_id!r}, PIPELINE_RUN={run_name!r})")
        return 0

    _score, metrics, tags = collect(results)
    tags.update({"pipeline_run": run_name, "model_id": model_id})
    params = {
        "model_id": model_id,
        "version": version,
        "modelcar_image": os.environ.get("MODELCAR_IMAGE", ""),
        "git_url": os.environ.get("GIT_URL", ""),
        "git_revision": os.environ.get("GIT_REVISION", ""),
    }

    try:
        import mlflow
        from mlflow.tracking import MlflowClient
    except ImportError as exc:
        warn(f"mlflow SDK not installed in this image ({exc})")
        return 0
    try:
        mlflow.set_tracking_uri(uri)
        exp = mlflow.set_experiment(experiment)
        client = MlflowClient()
        found = client.search_runs(
            [exp.experiment_id], filter_string=f"tags.pipeline_run = '{run_name}'", max_results=1
        )
        run_id = found[0].info.run_id if found else None
        with mlflow.start_run(run_id=run_id, run_name=None if run_id else run_name) as run:
            if not run_id:                      # params are immutable: only set on a new run
                mlflow.log_params({k: v for k, v in params.items() if v != ""})
            mlflow.set_tags(tags)
            mlflow.log_metrics(metrics)
            for f in sorted(results.glob("*.json")):
                mlflow.log_artifact(str(f), artifact_path="scan-result")
            print(f"[log-mlflow] {'updated' if run_id else 'logged'} run {run.info.run_id} "
                  f"({run_name}) in experiment '{experiment}': {len(metrics)} metrics, "
                  f"routing={tags.get('routing', '-')} S_total={metrics.get('S_total', '-')}")
    except Exception as exc:  # noqa: BLE001 - logging must never fail the pipeline
        warn(f"could not log to MLflow at {uri}: {type(exc).__name__}: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
