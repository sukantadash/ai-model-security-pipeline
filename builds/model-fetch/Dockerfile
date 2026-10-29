FROM registry.redhat.io/ubi9/python-312:latest
USER root
# dl.min.io/client/mc/.../mc now returns HTTP 410; pin a GitHub release binary.
RUN curl -fsSL https://github.com/minio/mc/releases/download/RELEASE.2025-08-13T08-35-41Z/mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z -o /tmp/mc && \
    install -m 0755 /tmp/mc /usr/bin/mc && \
    rm -f /tmp/mc && \
    pip install --no-cache-dir huggingface_hub magika
USER 1001
COPY scripts/ /scripts/
USER root
RUN chmod +x /scripts/*.sh
USER 1001
ENTRYPOINT ["/scripts/download-hf-model.sh"]
