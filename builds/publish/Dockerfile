FROM registry.redhat.io/ubi9/python-312:latest
USER root
# dl.min.io/client/mc/.../mc now returns HTTP 410; pin a GitHub release binary.
RUN curl -fsSL https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z -o /tmp/mc && \
    install -m 0755 /tmp/mc /usr/bin/mc && \
    rm -f /tmp/mc && \
    dnf install -y jq git skopeo && dnf clean all && \
    pip3 install --no-cache-dir pyyaml
# MLflow client + kubernetes-namespaced auth plugin (archive-results step log-mlflow).
# Skinny client: ~170 MB instead of ~600 MB; RHOAI 3.5 runs MLflow server 3.13.
RUN pip3 install --no-cache-dir "mlflow-skinny[kubernetes]>=3.11,<3.14"
USER 1001
COPY scripts/ /scripts/
USER root
RUN chmod +x /scripts/*.sh /scripts/*.py
USER 1001
ENTRYPOINT ["/scripts/publish-to-registry.sh"]
