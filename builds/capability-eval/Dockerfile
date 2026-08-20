FROM registry.redhat.io/ubi9/python-312:latest
RUN pip install --no-cache-dir lm-eval deepeval
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-capability-eval.sh"]
