# Copy from minio-s3-secret.yaml.template into each zone namespace.
#
# Quay (pull registry.redhat.io / base images during build):
#   cp quay-secret.yaml.template quay-secret.yaml  # edit credentials
#   oc apply -f quay-secret.yaml -n build-image
#   oc secrets link builder sudash-modelpipeline-pull-secret -n build-image
#   oc apply -f quay-secret.yaml -n model-ingress
#   oc apply -f quay-secret.yaml -n model-eval
#   oc apply -f quay-secret.yaml -n model-test
#
# MinIO S3 (model weights — all zones). KServe also needs s3-* annotations on
# this Secret (see minio-s3-secret.yaml.template); serve-llm-start sets them.
#   cp minio-s3-secret.yaml.template minio-s3-secret.yaml  # edit credentials
#   for ns in model-ingress model-eval model-sandbox model-test; do
#     oc apply -f minio-s3-secret.yaml -n "${ns}"
#   done
#
# model-test ODH connection secret (verified serving). script.sh Phase 15 sed's
# instances/model-test/model-connection-secret.yaml.template (PLACEHOLDER + minio creds).
#
# MinIO root (minio-system only — edit instances/minio/secret.yaml before overlay 05):
#
# Optional: git clone token for private git-url (key: token).
#   oc create secret generic git-auth -n model-eval --from-literal=token=<pat>
#
#   oc create secret generic hf-token -n model-ingress \
#     --from-literal=HF_TOKEN=<your-huggingface-token>
