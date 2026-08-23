FROM registry.redhat.io/ubi9/python-312:latest
USER root
RUN pip install --no-cache-dir garak promptfoo llm-guard
USER 1001
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-red-team.sh"]
