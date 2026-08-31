FROM registry.redhat.io/ubi9/python-312:latest
USER root
RUN curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc && \
    install -m 0755 /tmp/mc /usr/bin/mc && \
    rm -f /tmp/mc && \
    dnf install -y jq git && dnf clean all && \
    pip3 install --no-cache-dir pyyaml
USER 1001
COPY scripts/ /scripts/
USER root
RUN chmod +x /scripts/*.sh /scripts/*.py
USER 1001
ENTRYPOINT ["/scripts/publish-to-registry.sh"]
