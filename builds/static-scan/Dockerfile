FROM registry.redhat.io/ubi9/python-312:latest
RUN pip install --no-cache-dir modelaudit fickling
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-static-scan.sh"]
