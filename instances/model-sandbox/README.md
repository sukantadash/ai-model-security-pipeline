# model-sandbox

Persistent namespace for **untrusted** eval serving. The pipeline does not create or delete this namespace.

| Applied by | Files |
|------------|--------|
| Overlay 04 / `oc apply -k` (once) | namespace, NetworkPolicy, RBAC |
| `serve-llm-start` | `LLMInferenceService.yaml` — placeholder image → `oci://…:<model-id>-unverified` (Granite / Llama: `LLMInferenceService-<model>.yaml`) |
| `serve-llm-stop` | Deletes the CR only |
| Overlay 04 / `oc apply -k` (once) | `nemo-guardrails-serviceaccount.yaml` — NeMo SA, `view` RoleBinding, token Secret |
| `nemo-guardrails-start` | `NemoGuardrails` CR `guardrails-<run suffix>` + ConfigMaps, after dynamic-scan ([docs](../../docs/nemo-guardrails.md)) |
| `nemo-guardrails-stop` | Deletes that CR and its ConfigMaps |

Quay pull secret must exist in this namespace (gitops-scripts Phase 2) so KServe can pull the ModelCar image.
