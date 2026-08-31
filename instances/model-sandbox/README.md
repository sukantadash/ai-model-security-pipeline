# model-sandbox

Persistent namespace for **untrusted** eval serving. The pipeline does not create or delete this namespace.

| Applied by | Files |
|------------|--------|
| Overlay 04 / `oc apply -k` (once) | namespace, NetworkPolicy, RBAC |
| `serve-llm-start` | `LLMInferenceService.yaml` after patching name + `s3://models-ingress/<model-id>/` |
| `serve-llm-stop` | Deletes the CR only |

Copy `minio-s3` into this namespace (same secret as other zones). KServe reads S3 annotations on that Secret.
