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

On success, **`publish-artifact`** promotes to `s3://models-verified/...` and registers in RHOAI Model Registry. Update GitOps manifest placeholders from `publish.json` / PipelineRun results, then apply overlay 16 or let overlay 17 sync.
