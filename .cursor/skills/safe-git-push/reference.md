# This-repo patterns for safe-git-push

Expected **placeholders in tracked files** (do not treat as secrets):

| Token | Where |
|-------|--------|
| `CHANGE_ME_MINIO_ROOT_PASSWORD` | `instances/minio/secret.yaml`, `minio-s3-secret.yaml.template` |
| `CHANGE_ME_MODEL_REGISTRY_DB_PASSWORD` | `instances/model-registry/postgres-secret.yaml` |
| `<base64(username:password)>` | `quay-secret.yaml.template` |
| `REPLACE_WITH_CLUSTER_APPS_DOMAIN` | `instances/gateway/gateway.yaml`, `instances/guidellm-benchmark/guidellm-benchmark-job.yaml` |

**Must stay gitignored** (live copies; never `git add -f`):

- `quay-secret.yaml`
- `minio-s3-secret.yaml`

**Replace live public FQDNs** with `REPLACE_WITH_CLUSTER_APPS_DOMAIN` (cluster apps domain already includes `apps.`). In-cluster hosts (`*.svc`, `*.svc.cluster.local`) are fine.

**Do not rewrite** `script.sh` comments that tell the operator to substitute the domain locally.
