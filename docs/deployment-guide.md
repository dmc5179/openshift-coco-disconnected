# Deploying Confidential Containers on Disconnected OpenShift

A start-to-finish guide for deploying OpenShift Confidential Containers (CoCo)
on bare-metal servers with Intel TDX in a disconnected (air-gapped) environment.

This guide assumes you are starting with bare-metal servers that have not yet
been configured for TDX and an OpenShift cluster that does not yet have any
CoCo components installed.

## What you will build

```
  INTERNET-CONNECTED SIDE                    DISCONNECTED ENCLAVE
 ========================                   ======================

 Mirror registry                            OpenShift 4.21+ bare-metal cluster
   Operator catalogs                          ├── NFD (hardware detection)
   Container images                           ├── Intel Device Plugins (SGX)
                                              ├── Intel TDX DCAP (QGS + vsock proxy)
 Intel PCS API                                ├── Sandboxed Containers (kata-cc)
   Platform collateral  ──► sneakernet ──►    ├── Trustee (KBS + attestation)
   PCK certificates                           └── kata-cc workloads (TDX VMs)

 PCCS Client Tool                           PCCS (container or Helm chart)
   Fetches collateral                         Caches collateral for QGS
```

When a kata-cc pod starts, the following happens automatically:

1. The TDX VM boots with an encrypted memory region
2. QGS generates a TDX attestation quote using Intel SGX/DCAP
3. The quote is sent to the Trustee KBS for verification
4. KBS validates the quote against RVPS reference values
5. If attestation passes, KBS releases secrets to the workload
6. If attestation fails, the workload cannot access sealed resources

## Before you begin

You will need:

| Item | Where to get it |
|------|-----------------|
| Bare-metal servers with Intel TDX CPUs | 4th Gen Xeon Scalable (Sapphire Rapids) or newer |
| iDRAC or BMC access to the servers | For BIOS configuration |
| OpenShift 4.21.9+ installed on bare metal | With FIPS mode enabled |
| A mirror registry in the disconnected enclave | `registry:2`, Quay, or similar |
| An internet-connected RHEL 9 host | For mirroring images and fetching Intel collateral |
| Intel PCS API key (free) | [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions) |
| Red Hat pull secret | [console.redhat.com/openshift/downloads](https://console.redhat.com/openshift/downloads) |
| A way to transfer files between connected and disconnected sides | USB drive, data diode, etc. |

---

## Phase 1: Configure server BIOS for TDX

TDX must be enabled in the server BIOS before OpenShift can use it. This
requires several BIOS settings and usually two reboots.

### Option A: Automated via Redfish (Dell PowerEdge)

If you have Dell PowerEdge R660 or R760 servers, use the Redfish automation
scripts in `redfish-configure-tdx-bios/`:

```bash
cd redfish-configure-tdx-bios

# Audit current BIOS settings
python3 r660_tdx_audit.py --host <IDRAC_IP> --username root --password <PASSWORD>

# Remediate (applies settings and schedules reboot)
python3 r660_tdx_remediate.py --host <IDRAC_IP> --username root --password <PASSWORD>
```

See `redfish-configure-tdx-bios/PREREQUISITES.md` for the full list of
required settings and multi-reboot dependencies.

### Option B: Manual BIOS configuration

Enter the BIOS setup on each server and enable the following settings. The
exact menu paths vary by manufacturer, but the settings are:

| Setting | Value | Notes |
|---------|-------|-------|
| Intel TDX | Enabled | Under Processor Settings or Security |
| Intel SGX | Enabled | Required for TDX attestation |
| Total Memory Encryption (TME) | Enabled | Prerequisite for TDX |
| SGX Factory Reset | On (then Off) | See note below |
| SGX Auto MP Registration | Enabled | For platform registration |

**SGX Factory Reset**: To register the platform with Intel for attestation,
you must perform an SGX Factory Reset. This is a two-reboot sequence:

1. Set `SGX Factory Reset = On` and reboot
2. After reboot, set `SGX Factory Reset = Off` and reboot again
3. Verify `SGX Auto Registration Agent` shows the correct status

This step generates the Platform Manifest that identifies your server's
hardware to Intel's provisioning service.

### Verify TDX is enabled

After BIOS configuration and reboots, verify from the OS:

```bash
# Check TDX module is loaded
dmesg | grep -i tdx

# Check SGX devices exist
ls /dev/sgx_*
```

---

## Phase 2: Collect platform data from TDX hosts

Each TDX server needs to be registered with Intel's Provisioning Certification
Service (PCS) for remote attestation to work. This step extracts the Platform
Manifest from each server.

### Install the PCK Cert ID Retrieval Tool

On each bare-metal TDX host (before OpenShift is installed, or from a RHEL
live boot USB):

```bash
sudo dnf install -y sgx-pck-id-retrieval-tool
```

> **CoreOS note**: OpenShift CoreOS does not support `dnf`. Run this step
> before deploying CoreOS, or boot from RHEL live media temporarily. See
> `intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md` for options.

### Generate CSV files

```bash
sudo PCKIDRetrievalTool -f host_$(hostname -s).csv
```

This produces a CSV file containing the Platform Manifest, CPUSVN, PCESVN,
and QE ID for the host.

**Important**: This tool sets a one-time UEFI bit. If you need to re-run it,
you must perform an SGX Factory Reset in BIOS first.

### Gather all CSV files

Collect the `host_*.csv` file from every TDX server onto removable media.
These files are needed on the internet-connected side in Phase 3.

---

## Phase 3: Mirror images into the disconnected enclave

All container images, operator catalogs, and related artifacts must be
mirrored into the disconnected enclave's registry before any operators can
be deployed.

See `docs/mirroring.md` for the complete mirroring guide. The short version:

```bash
# On the internet-connected host with access to registry.redhat.io
oc-mirror --config imageset-config.yaml \
  docker://<mirror-registry>:<port> \
  --workspace file://$HOME/oc-mirror-workspace \
  --v2
```

The `imageset-config.yaml` in the repo root captures everything needed:
OpenShift release images, Red Hat operators (NFD, Sandboxed Containers,
Trustee, Local Storage), certified operators (Intel Device Plugins, Intel
TDX DCAP), and additional images (dm-verity, QGS, coco-tools, etc.).

Transfer the mirror workspace to the disconnected side and push images to
the mirror registry.

---

## Phase 4: Fetch Intel attestation collateral

On the internet-connected side, use the platform CSV files from Phase 2 to
fetch attestation collateral from Intel's PCS API.

### Option A: Automated script

```bash
cd intel-tdx-remote-attestation-disconnected

# Merge CSV files and fetch collateral
./scripts/fetch-platform-collateral.sh full ./csv-dir/ https://127.0.0.1:8081 \
  --api-key YOUR_INTEL_PCS_API_KEY \
  --admin-token YOUR_PCCS_ADMIN_TOKEN
```

### Option B: Step by step

```bash
cd intel-tdx-remote-attestation-disconnected

# 1. Build the container images
./build.sh

# 2. Merge CSV files into a platform list
podman run --rm \
  -v ./csv-dir:/data:Z -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py collect -d /data -o /output/platform_list.json

# 3. Fetch collateral from Intel PCS
podman run --rm -it \
  -v ./output:/output:Z \
  -w /opt/app-root/src/confidential-computing.tee.dcap/tools/PcsClientTool \
  quay.io/danclark/intel-tdx/pcs-client-tool:latest \
  python3 pcsclient.py fetch -i /output/platform_list.json \
  -o /output/platform_collaterals.json
```

When prompted, enter your Intel PCS API subscription key.

Transfer `output/platform_collaterals.json` and the PCCS container image
tarballs to the disconnected enclave via sneakernet.

See `intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md` for the
full walkthrough.

---

## Phase 5: Deploy PCCS in the disconnected enclave

The PCCS (Provisioning Certificate Caching Service) runs inside the disconnected
enclave and serves attestation collateral to TDX hosts. It can run as a Podman
container on a RHEL host or as a Helm chart on OpenShift.

### Option A: Podman on RHEL

```bash
# Generate TLS certificates
mkdir -p pccs-ssl-key
openssl req -x509 -newkey rsa:4096 \
  -keyout pccs-ssl-key/private.pem -out pccs-ssl-key/file.crt \
  -days 3650 -nodes -subj "/CN=PCCS"
chmod 644 pccs-ssl-key/private.pem

# Start PCCS
podman volume create pccs-data
podman run -d --name pccs --network host \
  -v pccs-data:/opt/intel/sgx-dcap-pccs/data:Z \
  -v ./pccs-ssl-key:/opt/intel/sgx-dcap-pccs/ssl_key:Z \
  quay.io/danclark/intel-tdx/pccs:latest

# Insert collateral
podman run --rm -it \
  -v ./platform_collaterals.json:/data/platform_collaterals.json:Z \
  --network host \
  -w /opt/app-root/src/confidential-computing.tee.dcap.pccs/PccsAdminTool \
  quay.io/danclark/intel-tdx/pccs-admin-tool:latest \
  python3 pccsadmin.py put --no-pccs-cert-check \
    -u https://127.0.0.1:8081/sgx/certification/v4/platformcollateral \
    -i /data/platform_collaterals.json
```

### Option B: Helm chart on OpenShift

```bash
helm install pccs intel-tdx-remote-attestation-disconnected/chart/pccs/ \
  --namespace pccs --create-namespace \
  --set pccs.adminToken=<token> \
  --set pccs.userToken=<token>
```

See `intel-tdx-remote-attestation-disconnected/chart/pccs/README.md` for
configuration options.

### Verify PCCS is serving collateral

```bash
curl -sk https://<PCCS_HOST>:8081/sgx/certification/v4/rootcacrl
```

A non-empty response (hex-encoded CRL data) confirms collateral is loaded.

### Configure QGS to reach PCCS

The Intel TDX DCAP operator's QGS DaemonSet has a default QCNL config that
points to `localhost:8081`. If PCCS is running in a separate pod or on a
different host, QGS cannot reach it with this default.

**If PCCS runs on the cluster** (Helm chart in `intel-pccs` namespace):

The QGS pods use pod networking, not hostNetwork. The PCCS service is at
`pccs.intel-pccs.svc.cluster.local:8081` but QGS's QCNL config points to
`localhost:8081`. You need to override the QCNL config.

Create a ConfigMap with the corrected QCNL:

```bash
cat <<'EOF' | oc apply -n intel-dcap -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: qcnl-config
  namespace: intel-dcap
data:
  sgx_default_qcnl.conf: |
    {
      "pccs_url": "https://pccs.intel-pccs.svc.cluster.local:8081/sgx/certification/v4/",
      "use_secure_cert": false,
      "retry_times": 6,
      "retry_delay": 10,
      "pck_cache_expire_hours": 168,
      "verify_collateral_cache_expire_hours": 168,
      "local_cache_only": false
    }
EOF
```

Then patch the QGS DaemonSet to mount it (note: the DCAP operator may revert
this change on reconcile — you may need to scale the operator to 0 first):

```bash
oc patch daemonset intel-tdx-dcap-qgs -n intel-dcap --type=json -p '[
  {"op":"add","path":"/spec/template/spec/volumes/-",
   "value":{"name":"qcnl-config","configMap":{"name":"qcnl-config"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-",
   "value":{"name":"qcnl-config","mountPath":"/etc/sgx_default_qcnl.conf",
            "subPath":"sgx_default_qcnl.conf"}}
]'
```

**If PCCS runs on a separate RHEL host**: Use the PCCS host's IP and port
8081 in the QCNL config above instead of the Kubernetes service URL.

### Network requirements

All OpenShift nodes running TDX workloads must be able to reach the PCCS on
port 8081. If PCCS runs on a separate host:

- Open TCP 8081 inbound on the PCCS host firewall
- If using Podman, run with `--network host` (rootless Podman `-p` only
  binds to localhost)

---

## Phase 6: Deploy CoCo operators via AutoShift

AutoShift uses ACM governance policies and GitOps to deploy operators. This
is the recommended deployment method for disconnected environments.

### 6.1 Install ACM and GitOps on the hub cluster

If not already installed, install Red Hat Advanced Cluster Management and
OpenShift GitOps on your hub cluster. AutoShift requires both.

### 6.2 Clone and configure the AutoShift repo

```bash
cd autoshiftv2-coco
```

Edit the CoCo clusterset values for your environment:

```bash
cp autoshift/values/clustersets/hub-baremetal-sno-coco.yaml \
   autoshift/values/clustersets/my-coco.yaml
```

Edit `my-coco.yaml` to set:

- Cluster labels (your cluster name)
- Mirror registry URL (if using `disconnected-mirror: 'true'`)
- Operator channels and versions

### 6.3 Enable CoCo operators

The CoCo profile enables these operators in dependency order:

| Order | Policy | What it deploys |
|-------|--------|-----------------|
| 1 | `node-feature-discovery` | NFD operator + CoCo NodeFeatureRule |
| 2 | `intel-device-plugins` | Intel Device Plugins + SgxDevicePlugin CR |
| 3 | `intel-tdx-dcap` | Intel TDX DCAP operator + QGS + vsock proxy |
| 4 | `sandboxed-containers` | Sandboxed Containers operator + KataConfig + MachineConfig |
| 5 | `trustee` | Trustee operator + KbsConfig + attestation config |

AutoShift handles the deployment order through policy dependencies.

### 6.4 Push and sync

Push the values to your Git server and trigger an ArgoCD sync:

```bash
git push origin coco-disconnected
# ArgoCD detects the change and creates ACM policies
```

### 6.5 Wait for deployment

Monitor the rollout:

```bash
# Check ACM policies
oc get policy -A | grep coco

# Check operators
oc get csv -A | grep -E 'sandboxed|trustee|nfd|intel'

# Check KataConfig
oc get kataconfig -A

# Watch node readiness (node reboots for MachineConfig)
oc get nodes -w
```

The MachineConfig for TDX kernel arguments (`kvm_intel.tdx=1`) triggers a
node reboot. On bare-metal servers, this typically takes 15-20 minutes.

---

## Phase 7: Post-deployment configuration

After all operators are deployed, several manual steps are needed.

### 7.1 Generate and apply RVPS reference values

RVPS reference values tell the attestation service what TDX measurements
to expect from legitimate VMs. Without these, attestation has no basis for
comparison.

```bash
# Generate reference values for your OCP version
./scripts/generate-rvps-reference-values.sh

# Apply to the cluster
oc apply -f scripts/rvps-output/rvps-reference-values.yaml

# Wire it into KBS
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{"kbsRvpsRefValuesConfigMapName":"rvps-reference-values"}}'
```

The operator automatically restarts KBS to pick up the new values.

### 7.2 Generate attestation key pair

KBS needs an EC P-256 key pair for signing attestation tokens. If not already
created:

```bash
# Generate key pair
openssl ecparam -name prime256v1 -genkey -noout -out kbs-attest.key
openssl req -new -x509 -key kbs-attest.key -out kbs-attest.crt \
  -days 3650 -subj "/CN=KBS Attestation"

# Create Kubernetes secrets
oc create secret generic kbs-attestation-key \
  -n trustee-operator-system --from-file=key=kbs-attest.key
oc create secret generic kbs-attestation-cert \
  -n trustee-operator-system --from-file=cert=kbs-attest.crt

# Update KbsConfig
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{
    "kbsAttestationKeySecretName":"kbs-attestation-key",
    "kbsAttestationCertSecretName":"kbs-attestation-cert"
  }}'
```

**Must be EC (ES256), not RSA.** The attestation token broker requires ECDSA
on the NIST P-256 curve.

### 7.3 Store secrets in KBS (optional)

If your workloads need secrets delivered through attestation:

```bash
# Store a secret
./scripts/kbs-secrets.sh set my-app db-password 's3cret'

# Register it with the operator
./scripts/kbs-secrets.sh register my-app db-password
```

See `docs/trustee-operations.md` for full KBS secret management documentation.

---

## Phase 8: Verify the deployment

### 8.1 Check all components

```bash
# NFD detected TDX hardware
oc get nodes -o json | jq '.items[].metadata.labels' | grep tdx

# Intel Device Plugins running
oc get pods -n intel-device-plugins-operator

# QGS and vsock-proxy running
oc get pods -n intel-dcap

# Sandboxed Containers operator and KataConfig
oc get csv -n openshift-sandboxed-containers-operator
oc get kataconfig

# Trustee KBS running
oc get pods -n trustee-operator-system

# kata-cc runtime class available
oc get runtimeclass kata-cc
```

### 8.2 Deploy a test pod

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: coco-test
  namespace: default
spec:
  runtimeClassName: kata-cc
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi:latest
    command: ["sleep", "3600"]
    resources:
      requests:
        memory: "4Gi"
      limits:
        memory: "4Gi"
  restartPolicy: Never
EOF
```

**Important**: kata-cc pods require at least 4Gi memory. The TDX VM itself
uses ~2GB; pods with 256Mi will be OOM-killed.

### 8.3 Verify the pod is running in a TDX VM

```bash
# Pod should be Running
oc get pod coco-test

# Check the VM is using TDX (from the node)
oc debug node/<node-name> -- chroot /host \
  bash -c 'ps aux | grep qemu | grep confidential-guest-support'
```

The QEMU process should show `confidential-guest-support=tdx` in its
arguments, confirming the VM is running with TDX memory encryption.

### 8.4 Verify CoCo policy enforcement

```bash
# This should be blocked by the CoCo policy
oc exec coco-test -- whoami
# Expected: error (exec is blocked in confidential containers)
```

If `oc exec` is blocked, CoCo policy enforcement is working.

### 8.5 Check attestation flow

```bash
# Check KBS logs for attestation requests
KBS_POD=$(oc get pods -n trustee-operator-system -l app=kbs \
  -o jsonpath='{.items[0].metadata.name}')
oc logs -n trustee-operator-system "$KBS_POD" -c kbs --tail=50
```

Look for `auth`, `attest`, and `resource` request logs. Successful
attestation shows 200 status codes for all three phases.

### 8.6 Clean up

```bash
oc delete pod coco-test
```

---

## Troubleshooting

### Pod stuck in ContainerCreating

- Check that KataConfig is ready: `oc get kataconfig -o yaml`
- Check the kata runtime is installed on the node:
  `oc debug node/<node> -- chroot /host ls /usr/libexec/kata/`
- Check for SELinux denials: `oc debug node/<node> -- chroot /host ausearch -m AVC -ts recent`

### Node not coming back after MachineConfig

Bare-metal server reboots take 15-20 minutes including POST, BIOS init, and
CoreOS boot. Wait the full duration before investigating.

### QGS pods not scheduling

The QGS DaemonSet containers require SGX device resources. Make sure:

- `SgxDevicePlugin` CR has `enclaveLimit >= 10` and `provisionLimit >= 10`
- The Intel Device Plugins operator is running
- Nodes have the `intel.feature.node.kubernetes.io/sgx` label

### Attestation failing

1. Check PCCS is reachable from the cluster:
   `curl -sk https://<PCCS_HOST>:8081/sgx/certification/v4/rootcacrl`
2. Check the vsock-proxy DaemonSet is running: `oc get pods -n intel-dcap`
3. Check RVPS reference values are loaded (see Phase 7.1)
4. Check the attestation key is EC, not RSA (see Phase 7.2)

### KBS config changes reverting

The Trustee operator manages the KBS ConfigMap via a reconcile loop. Do not
edit `kbs-config-cm` directly — use KbsConfig CR fields. If deployed via
AutoShift, ACM ConfigurationPolicy also enforces the ConfigMap, reverting
manual edits within seconds.

---

## Appendix: FIPS considerations

| Component | Status |
|-----------|--------|
| Kata guest kernel | FIPS validation in progress per Red Hat |
| Trustee KBS (UBI-based) | Respects host crypto policies |
| Intel PCCS (Node.js) | Not FIPS-validated — consider running on a separate host |
| dm-verity signing | Verify signing algorithms are FIPS-approved |
| Attestation keys | Must use EC P-256 or P-384 (FIPS-approved curves) |

---

## Appendix: Reference documents

| Document | Location | What it covers |
|----------|----------|----------------|
| Image mirroring | `docs/mirroring.md` | oc-mirror v2 setup, imageset config |
| Intel infrastructure | `docs/intel-infrastructure.md` | Connected-side PCS setup |
| PCCS deployment | `intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md` | Full PCCS lifecycle |
| BIOS configuration | `redfish-configure-tdx-bios/README.md` | Dell PowerEdge TDX BIOS scripts |
| Trustee operations | `docs/trustee-operations.md` | RVPS, KBS secrets, attestation keys |
| AutoShift quickstart | `AutoShift-CoCo-QuickStart.md` | AutoShift-specific deployment steps |
| Test plan | `docs/test-plan.md` | End-to-end validation checklist |
