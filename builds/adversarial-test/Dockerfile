FROM registry.redhat.io/ubi9/python-312:latest
COPY scripts/ /scripts/
USER root
RUN chmod +x /scripts/*.sh /scripts/*.py
USER 1001
