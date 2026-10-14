
RHOAI Red Hat OpenShift AI version 3.5.1

Once RHOAI is up and running:

Enable trustyai and mlflow in datasciencecluster
trustyai:
  managementState: Managed
mlflowoperator:
  managementState: Managed
Apply mlflow server CRD - In mlflow folder
Apply Postgres database, TrustyAIservice, and Evalhub CRD - In evalhub folder

## NOTE:
# Disable MCP guardrails mode — required for EvalHub controller to activate (G1) 
# if mcpGuardrailsMode is 'true', Evalhub cannot come up or be deleted. This is a bug.
oc patch datasciencecluster default-dsc --type=merge \
  -p '{"spec":{"components":{"trustyai":{"mcpGuardrailsMode":false}}}}'