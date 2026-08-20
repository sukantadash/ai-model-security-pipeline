FROM registry.redhat.io/ubi9/python-312:latest
RUN pip install --no-cache-dir garak promptfoo llm-guard
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-red-team.sh"]
