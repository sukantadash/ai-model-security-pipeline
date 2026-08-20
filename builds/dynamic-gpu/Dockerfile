FROM nvidia/cuda:12.4.1-runtime-ubi9
RUN dnf install -y python3.12 python3.12-pip && dnf clean all
RUN pip3.12 install --no-cache-dir torch safetensors
COPY scripts/ /scripts/
ENTRYPOINT ["/scripts/run-dynamic-gpu-load.sh"]
