
RHOAI Red Hat OpenShift AI version 3.5.1

Once RHOAI is up and running:

Enable trustyai and mlflow in datasciencecluster
trustyai:
  managementState: Managed
mlflowoperator:
  managementState: Managed
Apply mlflow server CRD - In mlflow folder
Apply Postgres database, TrustyAIservice, and Evalhub CRD - In evalhub folder
