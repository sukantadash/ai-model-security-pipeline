# Builds — Custom Tekton Task Images

Container images for the AI Model Security Pipeline evaluation tasks.

## Images

| BuildConfig | Context | Purpose |
|-------------|---------|---------|
| `ai-security-model-fetch` | `model-fetch/` | Download models from Hugging Face Hub |
| `ai-security-static-scan` | `static-scan/` | Static security scanning |
| `ai-security-dynamic-test` | `dynamic-test/` | Sandboxed runtime probe |
| `ai-security-capability-eval` | `capability-eval/` | Benchmark evaluation |
| `ai-security-red-team` | `red-team/` | Adversarial testing |
| `ai-security-score-gate` | `score-gate/` | Aggregate results, pass/fail |

## Local build (without cluster)

```bash
docker build -t ai-security-static-scan:latest builds/static-scan
```

## OpenShift build

2. Push this repo to Git (BuildConfigs use `source.type: Git` — URI is set to `https://github.com/sukantadash/ai-model-security-pipeline.git`).
3. Apply and build:

```bash
oc apply -f builds/build.yaml -n model-eval
oc start-build ai-security-static-scan --follow -n model-eval
```

## Push to Quay (optional)

After internal ImageStream build, tag and push to Quay for multi-cluster use:

```bash
oc import-image ai-security-static-scan:latest --confirm -n model-eval
# or configure BuildConfig output.to to ImageStreamTag on external Quay via push secret
```

Verified model artifacts (weights, not scanner images) are stored separately — see [IMPLEMENTATION-PLAN.md](../IMPLEMENTATION-PLAN.md) section 4.
