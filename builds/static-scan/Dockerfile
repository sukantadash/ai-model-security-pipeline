FROM registry.redhat.io/ubi9/python-312:latest
USER root

RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    /usr/bin/crb enable || true && \
    dnf install -y clamav clamav-freshclam && \
    dnf clean all

RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin && \
    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin

RUN pip install --no-cache-dir modelaudit fickling magika modelscan

RUN mkdir -p /var/lib/clamav /var/lib/grype && \
    freshclam --datadir=/var/lib/clamav && \
    GRYPE_DB_CACHE_DIR=/var/lib/grype grype db update && \
    chmod -R a+rX /var/lib/clamav /var/lib/grype /usr/local/bin

COPY scripts/ /scripts/
COPY policy.json /etc/static-scan/policy.json
RUN chmod +x /scripts/*.sh /scripts/*.py

USER 1001
ENV GRYPE_DB_CACHE_DIR=/var/lib/grype \
    GRYPE_DB_AUTO_UPDATE=false \
    CLAMAV_DB=/var/lib/clamav \
    STATIC_SCAN_POLICY=/etc/static-scan/policy.json \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    PROMPTFOO_DISABLE_SHARING=true
ENTRYPOINT ["/scripts/run-static-scan.sh"]
