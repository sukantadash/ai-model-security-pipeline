FROM registry.redhat.io/ubi9/python-312:latest
RUN curl -fsSL -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc && \
    chmod +x /usr/local/bin/mc && \
    pip install --no-cache-dir huggingface_hub magika
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/download-hf-model.sh"]
