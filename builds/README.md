# Builds — Custom Tekton Task Images

Container images for the AI Model Security Pipeline evaluation tasks.

Built in the **`build-image`** namespace (no zone NetworkPolicy). Tekton tasks in `model-eval` pull from the internal registry:

`image-registry.openshift-image-registry.svc:5000/build-image/ai-security-<name>:latest`

## Images

| BuildConfig | Context | Purpose |
|-------------|---------|---------|
| `ai-security-model-fetch` | `builds/model-fetch/` | Download models from Hugging Face Hub |
| `ai-security-static-scan` | `builds/static-scan/` | Static security scanning |
| `ai-security-dynamic-test` | `builds/dynamic-test/` | Sandboxed runtime probe |
| `ai-security-capability-eval` | `builds/capability-eval/` | Benchmark evaluation |
| `ai-security-adversarial-test` | `builds/adversarial-test/` | Adversarial testing (prompt injection, jailbreak, harmful content/bias) |
| `ai-security-score-gate` | `builds/score-gate/` | Weighted `S_total`, routing auto-pass/review/reject |
| `ai-security-publish` | `builds/publish/` | MinIO promote + Model Registry |

## OpenShift build

```bash
oc apply -k ./overlays/06-builds/
oc apply -f quay-secret.yaml -n build-image
oc secrets link builder sudash-modelpipeline-pull-secret -n build-image
for bc in model-fetch static-scan dynamic-test capability-eval adversarial-test score-gate publish; do
  oc start-build "ai-security-${bc}" --from-dir="builds/${bc}" --follow -n build-image
done
```

Single image:

```bash
oc start-build ai-security-static-scan --from-dir=builds/static-scan --follow -n build-image
```

## Local build (without cluster)

```bash
docker build -t ai-security-static-scan:latest builds/static-scan
```
