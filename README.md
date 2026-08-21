# OpenShift Confidential Containers — Disconnected Bare Metal

Deploy OpenShift Confidential Containers (CoCo) on bare-metal servers in a fully disconnected (air-gapped) enclave environment using Intel TDX.

## Overview

This repository orchestrates everything needed to run confidential container workloads on OpenShift bare metal without internet connectivity:

1. **Mirror** all required operators, images, and artifacts into the disconnected enclave
2. **Deploy operators** via [AutoShift](autoshiftv2-coco/) (GitOps-driven ACM policies)
3. **Set up Intel TDX attestation infrastructure** on the internet-connected side
4. **Configure** the OpenShift cluster for confidential containers with hardware-based attestation

Confidential containers run inside Intel TDX Trusted Execution Environments (TEEs) with memory encryption, verified through remote attestation using the Red Hat build of Trustee (KBS).

## Prerequisites

- OpenShift Container Platform **4.21.9 or later** installed on bare-metal servers with Intel TDX-capable hardware
- FIPS mode enabled on the target cluster (see [FIPS Notes](#fips-notes))
- A mirror registry accessible within the disconnected enclave
- An internet-connected host for fetching Intel attestation collateral and mirroring images
- Intel PCS API subscription key (free) from [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions)

## Architecture

```
  INTERNET-CONNECTED SIDE                    DISCONNECTED ENCLAVE
 ========================                   ======================

 oc-mirror                                  OpenShift Cluster (bare metal)
   registry.redhat.io ──► mirror registry ──► ├── NFD Operator
   certified catalog                         ├── Sandboxed Containers Operator
   additional images                         ├── Trustee Operator (KBS)
                                             ├── Intel TDX DCAP Operator
 Intel PCS API                               ├── Intel Device Plugins
   collateral fetch ──► sneakernet ──►       └── KataConfig (kata-cc runtime)
   PCK certificates
                                             Intel PCCS (if on separate host)
 PCS Client Tool                               └── Serves cached collateral
   merge platform CSVs                            to TDX hosts
   fetch collateral
```

## Repository Layout

| Path | Description |
|------|-------------|
| [`imageset-config.yaml`](imageset-config.yaml) | oc-mirror ImageSetConfiguration — all operators and images for disconnected mirroring |
| [`docs/`](docs/) | Detailed guides (mirroring, Intel infrastructure setup) |
| [`autoshiftv2-coco/`](autoshiftv2-coco/) | AutoShift fork — ACM policies to deploy all operators via GitOps |
| [`intel-tdx-remote-attestation-disconnected/`](intel-tdx-remote-attestation-disconnected/) | Containerized Intel TDX remote attestation tooling for disconnected environments |
| [`coco-pattern/`](coco-pattern/) | Reference repo (validated patterns model — used for context, not our deployment model) |
| [`trustee/`](trustee/) | Manual Trustee operator YAML (reference — AutoShift handles deployment) |
| [`sandboxed_containers/`](sandboxed_containers/) | Manual Intel DCAP and device plugin YAML (reference) |
| [`nfd-nodefeaturerule-combined.yaml`](nfd-nodefeaturerule-combined.yaml) | NodeFeatureRule for TDX/SNP/SGX hardware detection |
| [`machine-config-intel-tdx.yaml`](machine-config-intel-tdx.yaml) | MachineConfig for Intel TDX kernel arguments |
| [`kataconfig-cr.yaml`](kataconfig-cr.yaml) | KataConfig CR for confidential containers |
| [`osc-feature-gates.yaml`](osc-feature-gates.yaml) | Feature gates ConfigMap to enable confidential mode |

## Operators Required

All operators are deployed via AutoShift (ACM governance policies). Enable them with a single `coco: 'true'` label in the AutoShift clusterset values.

| Operator | Catalog | Purpose |
|----------|---------|---------|
| Node Feature Discovery (nfd) | redhat-operators | Detects Intel TDX / AMD SEV-SNP hardware capabilities |
| OpenShift Sandboxed Containers | redhat-operators | Provides kata-cc runtime class for confidential VMs |
| Red Hat build of Trustee | redhat-operators | Key Broker Service (KBS) for remote attestation and secret delivery |
| Intel Device Plugins | certified-operators | Exposes SGX/TDX device nodes to pods |
| Intel TDX DCAP | certified-operators | Manages QGS (Quote Generation Service) for TDX attestation |
| Local Storage Operator | redhat-operators | Storage provisioning (optional, for SNO deployments) |

## Quick Start

### 1. Mirror images into the enclave

See [`docs/mirroring.md`](docs/mirroring.md) for the full process.

```bash
oc-mirror --config imageset-config.yaml \
  docker://<mirror-registry-host>:<port> \
  --workspace file://$HOME/oc-mirror-workspace \
  --v2
```

### 2. Set up Intel attestation infrastructure

See [`docs/intel-infrastructure.md`](docs/intel-infrastructure.md) for internet-connected side setup.

See [`intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md`](intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md) for enclave-side PCCS deployment.

### 3. Deploy operators via AutoShift

In the AutoShift values, enable the CoCo profile:

```yaml
# autoshiftv2-coco/autoshift/values/clustersets/hub-baremetal-sno-coco.yaml
hubClusterSets:
  hub:
    labels:
      coco: 'true'                    # Top-level switch — enables all CoCo operators
      sandboxed-containers: 'true'    # Sandboxed Containers Operator
      trustee: 'true'                 # Trustee Operator (KBS)
      node-feature-discovery: 'true'  # NFD for hardware detection
      # ... subscription details auto-configured
```

### 4. Verify deployment

```bash
# Check operators are installed
oc get csv -n openshift-sandboxed-containers-operator
oc get csv -n trustee-operator-system
oc get csv -n openshift-nfd

# Check KataConfig is ready
oc get kataconfig -A

# Check Trustee KBS is running
oc get pods -n trustee-operator-system

# Verify TDX attestation
oc logs deployment/trustee-deployment -n trustee-operator-system -c kbs --tail=20
```

## Deployment Order

The operators must be deployed in a specific order due to dependencies:

1. **NFD** — must detect TDX/SNP hardware before sandboxed containers can configure kata
2. **Intel TDX MachineConfig** — enables TDX kernel modules (`kvm_intel.tdx=1`)
3. **Sandboxed Containers Operator** — installs kata runtime, deploys KataConfig
4. **Intel DCAP Operator** — deploys QGS for quote generation
5. **Trustee Operator** — deploys KBS for attestation and secret delivery
6. **Network config** — `routingViaHost: true` required for kata pod networking

AutoShift handles this ordering through policy dependencies.

## FIPS Notes

> **Assumption:** The target OpenShift cluster has FIPS mode enabled.

The following areas may require attention with FIPS:

- **Kata guest kernel**: The kata-cc guest VM uses its own kernel. Verify that the guest kernel and initrd shipped with OpenShift Sandboxed Containers 1.12 are FIPS-validated. Per Red Hat documentation, FIPS compliance for OpenShift sandboxed containers is in progress — check the [NIST CMVP status](https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules) for current validation state.
- **Trustee (KBS) TLS**: The KBS endpoint should use FIPS-approved TLS cipher suites. The Red Hat build of Trustee runs on UBI which respects the host's crypto policies.
- **Intel PCCS**: If running PCCS on the OpenShift cluster, its Node.js TLS stack is **not** FIPS-validated. Consider running PCCS on a separate RHEL host with FIPS-approved OpenSSL if FIPS compliance is required for all attestation traffic.
- **dm-verity**: Image signature verification uses cosign/sigstore — verify that the signing algorithms used are FIPS-approved.

## Additional Git Repos

| Repo | Purpose | Location |
|------|---------|----------|
| [intel-tdx-remote-attestation-disconnected](intel-tdx-remote-attestation-disconnected/) | Containerized Intel PCCS, PCS Client Tool, and Admin Tool for disconnected TDX attestation | Subdirectory (also at github.com/dmc5179/intel-tdx-remote-attestation-disconnected) |
| [autoshiftv2-coco](autoshiftv2-coco/) | Fork of AutoShift with CoCo operator policies added | Subdirectory |
| [coco-pattern](coco-pattern/) | Upstream validated patterns reference (we do NOT use Ansible validated patterns — reference only) | Subdirectory |
| [patterns-operator](patterns-operator/) | Patterns operator reference YAML (we do NOT use this — reference only) | Subdirectory |

## Key Files Reference

| File | What It Does |
|------|-------------|
| `nfd-nodefeaturerule-combined.yaml` | **Required** — NodeFeatureRule that detects kata runtime support, AMD SEV-SNP, Intel SGX, and Intel TDX hardware features |
| `machine-config-intel-tdx.yaml` | MachineConfig that enables `kvm_intel.tdx=1` kernel arg and loads `vsock-loopback` module |
| `kataconfig-cr.yaml` | KataConfig CR with `enablePeerPods: false` and `checkNodeEligibility: true` for bare metal |
| `osc-feature-gates.yaml` | ConfigMap enabling confidential containers mode (`confidential: "true"`) |
