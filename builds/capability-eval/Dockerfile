FROM registry.redhat.io/ubi9/python-312:latest
USER root
RUN pip install --no-cache-dir lm-eval deepeval
USER 1001
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-capability-eval.sh"]
