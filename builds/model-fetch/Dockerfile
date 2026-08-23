FROM registry.redhat.io/ubi9/python-312:latest
USER root
RUN curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc && \
    install -m 0755 /tmp/mc /usr/bin/mc && \
    rm -f /tmp/mc && \
    pip install --no-cache-dir huggingface_hub magika
USER 1001
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/download-hf-model.sh"]
