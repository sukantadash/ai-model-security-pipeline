FROM registry.redhat.io/ubi9/python-312:latest
USER root
RUN pip install --no-cache-dir modelaudit fickling
USER 1001
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-static-scan.sh"]
