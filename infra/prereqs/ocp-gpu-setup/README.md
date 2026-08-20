# OCP GPU Setup

Complete setup guide for enabling NVIDIA GPU support in OpenShift Container Platform (OCP) clusters running on AWS.

## Overview

This setup deploys a complete GPU-enabled OpenShift environment with:

- **GPU-enabled worker nodes** with NVIDIA L40S GPUs
- **Node Feature Discovery (NFD)** for hardware detection
- **NVIDIA GPU Operator** for automated GPU resource management
- **Custom configurations** for production GPU workloads

NFD and GPU Operator manifests live in repo root `operators/` and `instances/gpu/`, applied via overlays `00-gpu-operators` and `01-gpu-instances`.

## Step 1: Configure GPU Machine Sets

The machine set script creates AWS EC2 instances with GPU support and configures them as OpenShift worker nodes.

```bash
./machine-set/gpu-machineset.sh
```

**Configuration options:**

1. Select "12) L40S Single GPU" — Creates nodes with NVIDIA L40S GPUs
2. Choose "p" for private — Internal GPU access (vs "s" for shared/external)
3. Enter AWS region, probably "us-east-2"
4. Enter Availability zone e.g. "1"
5. Answer "n" for spot instances — Use on-demand instances for stability

Wait for nodes to be provisioned (typically 5–10 minutes).

## Step 2: Deploy Node Feature Discovery (NFD)

From the repo root:

```bash
oc apply -k ./overlays/00-gpu-operators/
oc wait --for=condition=Available subscription/nfd -n openshift-nfd --timeout=600s
oc wait --for=condition=Available subscription/gpu-operator-certified -n nvidia-gpu-operator --timeout=600s
```

## Step 3: Deploy NVIDIA GPU Operator

Included in overlay `00-gpu-operators` (same apply as Step 2).

## Step 4: Deploy Custom Resources (CRs)

From the repo root:

```bash
oc apply -k ./overlays/01-gpu-instances/
```

CR manifests: `instances/gpu/` (NFD config, cluster policy, driver).

## Verification

```bash
oc get nodes -l nvidia.com/gpu.present=true
oc get pods -n nvidia-gpu-operator
oc describe node <gpu-node-name> | grep nvidia.com/gpu
```

See [script.sh](../../script.sh) Phase 0 for the full runbook.
