# Copy from minio-s3-secret.yaml.template into each zone namespace.
#
# Quay (scanner images only):
#   cp quay-secret.yaml.template quay-secret.yaml  # edit credentials
#   oc apply -f quay-secret.yaml -n model-ingress
#   oc apply -f quay-secret.yaml -n model-eval
#   oc apply -f quay-secret.yaml -n model-prod
#
# MinIO S3 (model weights — all zones):
#   cp minio-s3-secret.yaml.template minio-s3-secret.yaml  # edit credentials
#   for ns in model-ingress model-eval model-prod; do
#     oc apply -f minio-s3-secret.yaml -n "${ns}"
#   done
#
# MinIO root (minio-system only — edit instances/minio/secret.yaml before overlay 05):
#
# Hugging Face token (ingress only):
#   oc create secret generic hf-token -n model-ingress \
#     --from-literal=HF_TOKEN=<your-huggingface-token>
