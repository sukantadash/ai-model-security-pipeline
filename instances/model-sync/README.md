# Ingress → eval artifact flow (MinIO)

Models land in **`s3://models-ingress/<model-id>/`** via the model-fetch Job.

The Tekton **`fetch-artifact`** task mirrors that prefix into the eval-workspace PVC at pipeline start. No manual `oc cp` required when MinIO is configured.

## Example: RedHatAI/Qwen3-8B-FP8-dynamic

```bash
# After Phase 5 builds and minio-s3 secrets applied:
oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml
oc wait --for=condition=complete job/model-fetch -n model-ingress --timeout=7200s

oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml
```

On success, **`publish-artifact`** promotes weights to `s3://models-verified/<model-id>/<version>/` (version = last five characters of the PipelineRun name) and registers in RHOAI Model Registry. Scan JSON is stored at `s3://models-eval/<model-id>/<version>/scan-result/` (each subtask uploads as it finishes). Update GitOps manifest placeholders from `publish.json` / PipelineRun results, then apply overlay 16 or let overlay 17 sync into **model-test**. Promotion to **model-prod** is a later manual process.
