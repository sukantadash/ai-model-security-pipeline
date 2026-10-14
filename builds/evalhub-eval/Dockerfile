FROM registry.redhat.io/ubi9/python-312:latest

USER root

RUN curl -fsSL \
      https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar -xz -C /usr/local/bin oc \
    && chmod +x /usr/local/bin/oc \
    && oc version --client

USER 1001
