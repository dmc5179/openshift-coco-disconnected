# Intel TDX Remote Attestation Infrastructure Setup

This guide covers setting up the Intel TDX remote attestation infrastructure on the **internet-connected side** in support of deploying Confidential Containers on a disconnected OpenShift cluster.

For enclave-side PCCS deployment, see [`intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md`](../intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md).

## Overview

Intel TDX attestation requires a chain of trust rooted in Intel's Provisioning Certification Service (PCS). In a disconnected environment, attestation collateral must be pre-fetched from the internet and loaded into a local PCCS (Provisioning Certificate Caching Service) inside the enclave.

```
  INTERNET-CONNECTED SIDE                    DISCONNECTED ENCLAVE
 ========================                   ======================

 1. Collect platform data           ◄──── host_*.csv files from PCKCIDRT
    (merge CSVs)                           on each TDX bare-metal host

 2. Fetch collateral from           ────► platform_collaterals.json
    Intel PCS API                          + container image tarballs

 3. Build container images          ────► pccs.tar, pccs-admin-tool.tar
    (PCCS, Admin Tool)
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Intel PCS API key | Free — register at [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions) |
| Podman or Docker | On the internet-connected build host |
| `sgx-pck-id-retrieval-tool` | Installed on each TDX host in the enclave (bare metal RPM) |
| Sneakernet mechanism | USB drive, data diode, or write-once media to transfer files between sides |

## Step 1: Build Intel Attestation Container Images

On the internet-connected side, build the containerized attestation tooling from the [`intel-tdx-remote-attestation-disconnected`](../intel-tdx-remote-attestation-disconnected/) repo.

```bash
cd intel-tdx-remote-attestation-disconnected
./build.sh
```

This builds four container images:

| Image | Purpose | Runs On |
|-------|---------|---------|
| `pcs-base` | Base image with Intel DCAP repo (build dependency only) | N/A |
| `pcs-client-tool` | Merges platform CSVs, fetches collateral from Intel PCS | Internet-connected side |
| `pccs-admin-tool` | Inserts collateral into PCCS database | Disconnected enclave |
| `pccs` | Caching service for attestation collateral (OFFLINE mode) | Disconnected enclave |

The build script exports tarballs to `./images/` for sneakernet transfer:

```
images/
  pcs-client-tool.tar     # stays on connected side
  pccs-admin-tool.tar     # transfer to enclave
  pccs.tar                # transfer to enclave
```

## Step 2: Collect Platform Data from TDX Hosts

On **each TDX bare-metal host** in the disconnected enclave, run the PCK Cert ID Retrieval Tool (PCKCIDRT) to extract the Platform Manifest.

> **Why bare metal?** PCKCIDRT requires direct SGX hardware access through `/dev/sgx_provision` and reads UEFI variables. It cannot run in a container. See [`intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md`](../intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md#why-pckcidrt-cannot-be-containerized) for details.

### Install the tool

```bash
sudo dnf install -y sgx-pck-id-retrieval-tool
```

> **Note on OpenShift:** The PCKCIDRT RPM is designed for standard Linux hosts. On OpenShift CoreOS (RHCOS) worker nodes, you cannot install RPMs directly. Options:
> 1. Run PCKCIDRT on the host before OpenShift is installed (during RHCOS provisioning)
> 2. Use `oc debug node/<node-name>` to get a privileged shell, but PCKCIDRT may not be available in the debug container
> 3. Run PCKCIDRT from a separate RHEL host that has the same TDX hardware (same QE ID)
>
> This is an area where the tooling is designed for upstream Linux, not OpenShift specifically. Plan to run PCKCIDRT during initial bare-metal provisioning before OpenShift install.

### Generate the platform CSV

```bash
sudo PCKIDRetrievalTool -f host_$(hostnamectl --static).csv
```

This produces a file like `host_tdxserver01.csv` containing the Platform Manifest, PPID, CPUSVN, PCESVN, PCEID, and QE_ID.

> **WARNING:** PCKCIDRT sets a one-time UEFI bit that prevents the Platform Manifest from being presented again. If you need to re-run it, an **SGX Factory Reset** in BIOS is required. Handle CSV files carefully.

### Collect all CSV files

Gather all `host_*.csv` files from every TDX host onto removable media for transfer to the internet-connected side.

## Step 3: Fetch Collateral from Intel PCS

On the internet-connected side, use the PCS Client Tool container to merge platform data and fetch attestation collateral.

### Merge CSV files

**Automated (recommended):**

```bash
mkdir -p ./platform-data
cp /media/sneakernet/host_*.csv ./platform-data/

cd intel-tdx-remote-attestation-disconnected
./scripts/fetch-platform-collateral.sh collect ./platform-data/
```

**Manual:**

```bash
mkdir -p ./platform-data ./output
cp /media/sneakernet/host_*.csv ./platform-data/

podman run --rm \
  -v ./platform-data:/data:Z \
  -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py collect -d /data -o /output/platform_list.json
```

### Fetch collateral

**Automated (recommended):**

```bash
cd intel-tdx-remote-attestation-disconnected

# Merge CSVs and fetch in two steps
./scripts/fetch-platform-collateral.sh collect ./platform-data/
./scripts/fetch-platform-collateral.sh fetch --api-key YOUR_INTEL_PCS_API_KEY
```

The script pipes the API key via stdin to the PCS Client Tool container
(the tool uses `getpass`, not environment variables).

**Manual:**

```bash
podman run --rm -it \
  -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py fetch \
    -i /output/platform_list.json \
    -o /output/platform_collaterals.json
```

When prompted, enter your Intel PCS API subscription key.

This contacts `api.trustedservices.intel.com` and produces `platform_collaterals.json` containing PCK Certificates and Quote Verification Collateral for all platforms.

## Step 4: Transfer to the Disconnected Enclave

Copy the following to removable media:

| What | File | Transfer Direction |
|------|------|-------------------|
| PCCS container image | `images/pccs.tar` | Connected → Enclave |
| Admin Tool container image | `images/pccs-admin-tool.tar` | Connected → Enclave |
| Attestation collateral | `output/platform_collaterals.json` | Connected → Enclave |

## Step 5: Deploy PCCS in the Enclave

See [`intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md`](../intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md) for complete deployment instructions covering:

- **Podman deployment** on a standalone RHEL host
- **OpenShift deployment** as a Deployment + Service + Route on the cluster
- Loading collateral via the PCCS Admin Tool
- Configuring TDX hosts' QCNL to point at the PCCS

### OpenShift vs. Standalone Deployment

| Consideration | OpenShift | Standalone RHEL Host |
|--------------|-----------|---------------------|
| High availability | Pod restart via Deployment | Manual, systemd service |
| Network access | Cluster Service + Route | Direct IP/port |
| FIPS compliance | Node.js in PCCS is **not** FIPS-validated — may not satisfy strict FIPS requirements | Same concern, but can use FIPS-mode RHEL with OpenSSL |
| Storage | PVC for SQLite database | Local filesystem |

> **FIPS consideration:** The Intel PCCS is a Node.js application. Node.js does not use a FIPS-validated cryptographic module. If your security policy requires FIPS validation for all TLS endpoints, consider running PCCS on a dedicated RHEL host with FIPS-mode OpenSSL rather than on the OpenShift cluster.

## Collateral Refresh

Quote Verification Collateral expires after approximately **30 days** (`nextUpdate` field). To refresh:

1. On the connected side, re-run `pcsclient.py fetch` (no need to re-collect CSVs)
2. Transfer the new `platform_collaterals.json` to the enclave
3. Re-run the PCCS Admin Tool to update the cache

You do **not** need to re-run PCKCIDRT unless there has been a TCB change (firmware/microcode update on the TDX host).

## Adding New TDX Hosts

1. Install `sgx-pck-id-retrieval-tool` on the new host
2. Run `PCKIDRetrievalTool -f host_$(hostnamectl --static).csv`
3. Transfer the CSV to the connected side
4. Re-run `pcsclient.py collect` with all CSVs (old + new) and `pcsclient.py fetch`
5. Transfer updated `platform_collaterals.json` and re-run the Admin Tool

## TCB Recovery

If Intel releases a microcode/firmware update that changes TCB:

1. Apply the update on affected hosts
2. Perform **SGX Factory Reset** in BIOS
3. Re-run PCKCIDRT to generate new CSVs
4. Follow the full flow from Step 2 onward

## Reference

- [Intel TDX Remote Attestation Infrastructure Setup](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/)
- [Red Hat: Deploying confidential containers on bare-metal servers](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_confidential_containers_on_bare-metal_servers/)
- [Red Hat: Deploying Trustee in a disconnected environment](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_red_hat_build_of_trustee_for_workloads_running_on_bare-metal_servers_in_a_disconnected_environment/)
