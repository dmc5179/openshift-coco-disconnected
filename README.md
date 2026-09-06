# OpenShift Confidential Containers — Disconnected Bare Metal

Deploy OpenShift Confidential Containers (CoCo) on bare-metal Intel TDX servers
in a fully disconnected (air-gapped) environment. All operators deploy via
AutoShift (ACM governance policies through GitOps). FIPS is enabled.

## Getting Started

Follow the phases below in order. Each phase links to detailed documentation.

| Phase | What | Where | Side |
|-------|------|-------|------|
| **0** | [Set up infrastructure hosts](#phase-0-infrastructure-hosts) | This page | Both |
| **1** | [Configure server BIOS for TDX](#phase-1-configure-bios-for-tdx) | This page + [`redfish-configure-tdx-bios/`](redfish-configure-tdx-bios/) | Disconnected |
| **2** | [Collect platform data from TDX hosts](#phase-2-collect-platform-data) | [`docs/intel-infrastructure.md`](docs/intel-infrastructure.md) | Disconnected |
| **3** | [Mirror images into the enclave](#phase-3-mirror-images) | [`docs/mirroring.md`](docs/mirroring.md) | Connected → Disconnected |
| **4** | [Fetch Intel attestation collateral](#phase-4-fetch-attestation-collateral) | [`docs/intel-infrastructure.md`](docs/intel-infrastructure.md) | Connected |
| **5** | [Deploy PCCS](#phase-5-deploy-pccs) | [`docs/deployment-guide.md` Phase 5](docs/deployment-guide.md#phase-5-deploy-pccs-in-the-disconnected-enclave) | Both |
| **6** | [Deploy CoCo operators via AutoShift](#phase-6-deploy-coco-via-autoshift) | [`AutoShift-CoCo-QuickStart.md`](AutoShift-CoCo-QuickStart.md) | Disconnected |
| **7** | [Post-deployment configuration](#phase-7-post-deployment) | [`docs/trustee-operations.md`](docs/trustee-operations.md) | Disconnected |
| **8** | [Validate the deployment](#phase-8-validate) | [`docs/test-plan.md`](docs/test-plan.md) | Disconnected |

For the full end-to-end walkthrough with every command, see
[`docs/deployment-guide.md`](docs/deployment-guide.md).

---

## Architecture

```
  INTERNET-CONNECTED SIDE                    AIR GAP       DISCONNECTED ENCLAVE
 ========================                   =========     ======================

 RHEL 9 Server (connected)                               OpenShift 4.21+ Cluster
 ├── oc-mirror v2                                         ├── NFD Operator
 │   registry.redhat.io ────────────────► mirror ──────► ├── Intel Device Plugins
 │   certified catalog                    registry        ├── Intel TDX DCAP (QGS)
 │   additional images                                    ├── Sandboxed Containers
 │                                                        ├── Trustee (KBS)
 ├── PCS Client Tool                                      └── kata-cc workloads
 │   merge platform CSVs ◄── sneakernet ◄── host_*.csv
 │   fetch collateral ──────► sneakernet ──────►         RHEL 9 Server (disconnected)
 │                                                        ├── Mirror registry
 └── PCCS (optional, for testing)                         ├── PCCS (collateral cache)
                                                          └── Platform collateral
```

---

## Phase 0: Infrastructure Hosts

You need two RHEL 9 servers and an OpenShift cluster:

| Host | Network | Purpose |
|------|---------|---------|
| **Connected RHEL 9** | Internet access | Mirror images, fetch Intel collateral, build container images |
| **Disconnected RHEL 9** | Enclave only | Run mirror registry, PCCS, serve as a jump host |
| **OpenShift cluster** | Enclave only | Bare-metal 4.21.9+, FIPS enabled, Intel TDX-capable CPUs |

### Connected RHEL 9 setup

```bash
# Install prerequisites
sudo dnf install -y podman skopeo jq openssl python3

# Install oc-mirror v2 (must match OCP version)
# Download from: https://console.redhat.com/openshift/downloads
tar xf oc-mirror.tar.gz -C /usr/local/bin/

# Install oc CLI
tar xf openshift-client-linux.tar.gz -C /usr/local/bin/

# Clone this repo
git clone https://github.com/dmc5179/openshift-coco-disconnected.git
cd openshift-coco-disconnected
git submodule update --init

# Build Intel attestation container images
cd intel-tdx-remote-attestation-disconnected
./build.sh
```

### Disconnected RHEL 9 setup

```bash
# Install prerequisites
sudo dnf install -y podman skopeo jq openssl

# Set up the mirror registry (see docs/mirroring.md for full details)
# Transfer oc-mirror workspace from connected side via sneakernet

# Load PCCS and Admin Tool container images (transferred from connected side)
podman load -i pccs.tar
podman load -i pccs-admin-tool.tar
```

### What gets transferred across the air gap

| Artifact | Direction | Size | Purpose |
|----------|-----------|------|---------|
| oc-mirror workspace | Connected → Disconnected | ~50-80 GB | All container images and operator catalogs |
| `host_*.csv` files | Disconnected → Connected | ~1 KB each | Platform manifests from TDX hosts |
| `platform_collaterals.json` | Connected → Disconnected | ~500 KB | PCK certs and quote verification data |
| PCCS container images | Connected → Disconnected | ~500 MB | `pccs.tar`, `pccs-admin-tool.tar` |
| `rekor.pub`, `cosign-pub-key.pem` | Connected → Disconnected | ~1 KB each | Sigstore verification keys |

---

## Phase 1: Configure BIOS for TDX

TDX must be enabled in server BIOS before OpenShift can use it.

**Required BIOS settings:**

| Setting | Value |
|---------|-------|
| Intel TDX | Enabled |
| Intel SGX | Enabled |
| Total Memory Encryption (TME) | Enabled |
| SGX Factory Reset | On → reboot → Off → reboot |
| SGX Auto MP Registration | Enabled |

**Automated (Dell PowerEdge):** Use the Redfish scripts in
[`redfish-configure-tdx-bios/`](redfish-configure-tdx-bios/).

**Manual:** See [`docs/deployment-guide.md` Phase 1](docs/deployment-guide.md#phase-1-configure-server-bios-for-tdx).

After BIOS configuration, verify from the OS:
```bash
dmesg | grep -i tdx        # TDX module loaded
ls /dev/sgx_*               # SGX devices present
```

---

## Phase 2: Collect Platform Data

On each TDX bare-metal host, extract the Platform Manifest:

```bash
sudo dnf install -y sgx-pck-id-retrieval-tool
sudo PCKIDRetrievalTool -f host_$(hostname -s).csv
```

Transfer all `host_*.csv` files to the connected RHEL server via sneakernet.

See [`docs/intel-infrastructure.md`](docs/intel-infrastructure.md) Step 2 for
details and CoreOS considerations.

---

## Phase 3: Mirror Images

Mirror all required images into the disconnected enclave's registry.

**What gets mirrored:**

| Category | Contents |
|----------|----------|
| OCP Platform | OpenShift 4.21.x release images |
| Red Hat Operators | NFD, Sandboxed Containers, Trustee, Local Storage, LVM Storage |
| Certified Operators | Intel Device Plugins, Intel TDX DCAP |
| Additional Images | dm-verity, NFD operand, Intel QGS, CoCo tools |

```bash
# On the connected RHEL server
oc-mirror --config imageset-config.yaml \
  docker://<mirror-registry>:<port> \
  --workspace file://$HOME/oc-mirror-workspace --v2
```

Transfer the workspace to the disconnected side and apply cluster resources.

Full guide: [`docs/mirroring.md`](docs/mirroring.md)

---

## Phase 4: Fetch Attestation Collateral

On the connected RHEL server, fetch attestation collateral from Intel PCS:

```bash
cd intel-tdx-remote-attestation-disconnected

# Merge CSV files from all TDX hosts
./scripts/fetch-platform-collateral.sh collect /path/to/csv-dir/

# Fetch collateral from Intel PCS (requires API key)
./scripts/fetch-platform-collateral.sh fetch --api-key YOUR_INTEL_PCS_API_KEY
```

Transfer `collateral-output/platform_collaterals.json` to the disconnected side.

Get a free API key at:
[api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions)

Full guide: [`docs/intel-infrastructure.md`](docs/intel-infrastructure.md)

---

## Phase 5: Deploy PCCS

Deploy PCCS in the disconnected enclave to serve attestation collateral.

### Option A: Podman on the disconnected RHEL server

```bash
# Start PCCS
podman run -d --name pccs --network host \
  -v pccs-data:/opt/intel/sgx-dcap-pccs/data:Z \
  -v ./pccs-ssl-key:/opt/intel/sgx-dcap-pccs/ssl_key:Z \
  quay.io/danclark/intel-tdx/pccs:latest

# Insert collateral (default admin token: my-admin-token)
./scripts/fetch-platform-collateral.sh insert https://localhost:8081 \
  --admin-token my-admin-token
```

### Option B: Helm chart on OpenShift

```bash
helm install pccs intel-tdx-remote-attestation-disconnected/chart/pccs/ \
  --namespace intel-pccs --create-namespace
# Default tokens are baked into values.yaml:
#   admin = my-admin-token, user = my-user-token
```

Full guide: [`docs/deployment-guide.md` Phase 5](docs/deployment-guide.md#phase-5-deploy-pccs-in-the-disconnected-enclave)

---

## Phase 6: Deploy CoCo via AutoShift

AutoShift deploys all CoCo operators via ACM governance policies and GitOps.

**Operators deployed (in dependency order):**

| Order | Operator | Purpose |
|-------|----------|---------|
| 1 | Node Feature Discovery | Detects TDX/SNP/SGX hardware |
| 2 | Intel Device Plugins | Provides SGX device resources |
| 3 | Intel TDX DCAP | QGS + vsock proxy for quote generation |
| 4 | Sandboxed Containers | kata-cc runtime + KataConfig + MachineConfig |
| 5 | Trustee | KBS for attestation and secret delivery |

Full step-by-step: [`AutoShift-CoCo-QuickStart.md`](AutoShift-CoCo-QuickStart.md)

---

## Phase 7: Post-Deployment

After operators are deployed, complete these manual steps:

1. **Generate attestation key pair** (EC P-256, not RSA)
2. **Generate RVPS reference values** from kata guest images
3. **Store secrets in KBS** for workload delivery
4. **Configure KBS QCNL** to reach PCCS for quote verification

Full guide: [`docs/trustee-operations.md`](docs/trustee-operations.md)

Scripts:
- `scripts/generate-rvps-reference-values.sh` — compute TDX measurements
- `scripts/kbs-secrets.sh` — manage KBS repository secrets
- `scripts/generate-initdata.sh` — generate `cc_init_data` annotation

---

## Phase 8: Validate

### Quick smoke test

```bash
# Verify kata-cc runtime is available
oc get runtimeclass kata-cc

# Deploy a test pod (requires 4Gi memory minimum)
oc apply -f testbed/workloads/coco-attestation-test.yaml

# Check attestation logs
oc logs -n trustee-operator-system -l app=kbs -c kbs --tail=20
```

### Full attestation test with sealed secrets

```bash
# Store a test secret in KBS
./scripts/kbs-secrets.sh set attestation-test test-value 'my-secret'
./scripts/kbs-secrets.sh register attestation-test test-value

# Generate initdata and deploy test pod
INITDATA=$(./scripts/generate-initdata.sh debug)
sed "s|REPLACE_WITH_INITDATA|$INITDATA|" \
  testbed/workloads/coco-attestation-test.yaml | oc apply -f -

# Check results
oc logs coco-attestation-test -c fetch-secret
oc logs coco-attestation-test -c result
```

Full test plan: [`docs/test-plan.md`](docs/test-plan.md)

---

## Pre-Flight Checks

Run before deployment to verify prerequisites:

```bash
# Check cluster readiness
./scripts/preflight-cluster.sh

# Check RHEL 9 host readiness
./scripts/preflight-rhel9.sh
```

---

## Repository Layout

| Path | Description |
|------|-------------|
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Complete end-to-end deployment guide |
| [`docs/mirroring.md`](docs/mirroring.md) | Disconnected image mirroring guide |
| [`docs/intel-infrastructure.md`](docs/intel-infrastructure.md) | Intel TDX attestation infrastructure setup |
| [`docs/trustee-operations.md`](docs/trustee-operations.md) | KBS secrets, RVPS, attestation keys |
| [`docs/test-plan.md`](docs/test-plan.md) | End-to-end validation checklist |
| [`docs/rfe-trustee-rvps-local-json.md`](docs/rfe-trustee-rvps-local-json.md) | RFE: RVPS local_json operator bug |
| [`docs/rfe-trustee-kbs-dirpath-migration.md`](docs/rfe-trustee-kbs-dirpath-migration.md) | RFE: KBS dir_path migration bug |
| [`AutoShift-CoCo-QuickStart.md`](AutoShift-CoCo-QuickStart.md) | AutoShift deployment quick start |
| [`imageset-config.yaml`](imageset-config.yaml) | oc-mirror v2 config (all operators + images) |
| [`autoshiftv2-coco/`](autoshiftv2-coco/) | AutoShift fork with CoCo policies |
| [`intel-tdx-remote-attestation-disconnected/`](intel-tdx-remote-attestation-disconnected/) | Intel PCCS, PCS Client Tool, Admin Tool |
| [`redfish-configure-tdx-bios/`](redfish-configure-tdx-bios/) | Dell PowerEdge BIOS automation |
| [`scripts/`](scripts/) | Operational scripts (preflight, RVPS, KBS secrets, initdata) |
| [`testbed/`](testbed/) | Test workloads and cluster config |

## Sub-Repositories

Three directories are separate git repos with their own branches and remotes:

| Directory | Role | Our changes? |
|-----------|------|-------------|
| `autoshiftv2-coco/` | ACM policies for operator deployment | Yes — `coco-disconnected` branch |
| `intel-tdx-remote-attestation-disconnected/` | Containerized PCCS and tools | Yes — `main` branch |
| `coco-pattern/` | Upstream validated patterns (reference only) | No — read-only |

---

## Key Operational Notes

- **kata-cc pods require >= 4Gi memory** — TDX VM uses 2048M; 256Mi causes OOM
- **SgxDevicePlugin limits >= 10** — QGS DaemonSet needs 3 containers x SGX resources
- **KBS ConfigMap is operator-managed** — do NOT edit directly; use KbsConfig CR
- **Attestation keys must be EC P-256** — not RSA (ES256 required)
- **Bare-metal reboots take 15-20 min** — wait the full duration after MachineConfig
- **ACM policies revert manual edits** — changes go through `autoshiftv2-coco/` git repo

## FIPS Notes

| Component | Status |
|-----------|--------|
| Kata guest kernel | FIPS validation in progress per Red Hat |
| Trustee KBS (UBI-based) | Respects host crypto policies |
| Intel PCCS (Node.js) | Not FIPS-validated — consider separate RHEL host |
| Attestation keys | Must use FIPS-approved curves (P-256 or P-384) |
