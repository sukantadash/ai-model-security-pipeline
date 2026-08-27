FROM registry.redhat.io/ubi9/python-312:latest
COPY scripts/ /scripts/
COPY policy.json /etc/score-gate/policy.json
USER root
RUN chmod +x /scripts/*.py
USER 1001
ENV SCORE_GATE_POLICY=/etc/score-gate/policy.json
ENTRYPOINT ["python", "/scripts/aggregate-results.py"]
