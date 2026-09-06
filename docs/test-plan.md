# End-to-End Test Plan: CoCo on Disconnected Bare Metal

## Environment

| Component | Details |
|-----------|---------|
| RHEL 9 VM | Internet-connected side. `ec2-user` with sudo. Builds attestation containers, fetches Intel collateral. |
| OpenShift cluster | Target cluster. Bare metal, FIPS enabled, OCP 4.21.9+. |
| Intel PCS key | Required for fetching attestation collateral from Intel. |

## Pre-Deployment Questions

Answer these before we start — they determine what steps to run:

1. **Is the cluster actually disconnected?** If connected, we skip oc-mirror
   and deploy operators directly from upstream catalogs. The AutoShift policies
   work either way (`disconnected-mirror: 'false'`).
2. **Is ACM + ArgoCD already installed?** If not, we deploy operators manually
   first (AutoShift requires ACM + GitOps on the hub). Can also test policies
   manually via `oc apply` without the full AutoShift pipeline.
3. **Does the cluster have TDX hardware?** If not, we can deploy and configure
   everything but the runtime won't actually create confidential VMs.
4. **Is this SNO or multi-node?**
5. **Is there a mirror registry?** If disconnected, where is it?

## Phase 1: Pre-Flight (no changes)

Run from the local machine or RHEL 9 VM. Read-only checks.

- [ ] Run `scripts/preflight-rhel9.sh` on the RHEL 9 VM
- [ ] Run `scripts/preflight-cluster.sh` against the OCP cluster
- [ ] Record cluster version, node count, FIPS status, existing operators
- [ ] Identify which operators are already installed vs. need deployment
- [ ] Verify CatalogSources are healthy (redhat-operators, certified-operators)

## Phase 2: Intel Attestation Infrastructure (RHEL 9 VM)

Internet-connected side. Can run in parallel with Phase 3.

- [ ] Clone `intel-tdx-remote-attestation-disconnected` onto the VM
- [ ] Build container images: `./build.sh`
- [ ] Verify images built: `podman images | grep intel-tdx`
- [ ] If cluster has TDX hardware:
  - [ ] Collect platform CSV from each TDX host (PCKCIDRT)
  - [ ] Transfer CSVs to VM
  - [ ] Run PCS Client Tool to merge CSVs and fetch collateral
  - [ ] Verify `platform_collaterals.json` was created
- [ ] If no TDX hardware: skip PCKCIDRT, note that QGS won't function

## Phase 3: Operator Deployment (OpenShift Cluster)

Deploy operators in order. Two paths depending on whether AutoShift (ACM +
ArgoCD) is available.

### Path A: Direct `oc apply` (no AutoShift)

Test the operators and CRs directly, without ACM policies.

**Step 3A.1: Node Feature Discovery**
- [ ] Install NFD operator (if not already installed)
- [ ] Create NodeFeatureDiscovery instance
- [ ] Apply `nfd-nodefeaturerule-combined.yaml`
- [ ] Verify labels: `oc get nodes -L intel.feature.node.kubernetes.io/tdx`

**Step 3A.2: Intel Device Plugins**
- [ ] Install intel-device-plugins-operator from certified-operators
- [ ] Create SgxDevicePlugin CR
- [ ] Verify SGX resources: `oc describe node | grep sgx.intel.com`

**Step 3A.3: Intel TDX DCAP**
- [ ] Install intel-tdx-dcap-operator from certified-operators (alpha channel)
- [ ] Verify CRDs installed: `oc get crd | grep intel`
- [ ] Record actual CRD API version and spec schema (may differ from our CR)
- [ ] Create QGS CR (adjust if schema differs)

**Step 3A.4: Apply TDX MachineConfig**
- [ ] Apply `machine-config-intel-tdx.yaml`
- [ ] Wait for MachineConfigPool to finish rolling: `oc get mcp`
- [ ] Verify kernel args on a node: `oc debug node/<node> -- chroot /host cat /proc/cmdline`

**Step 3A.5: OpenShift Sandboxed Containers**
- [ ] Install sandboxed-containers-operator
- [ ] Apply `osc-feature-gates.yaml` (confidential: "true")
- [ ] Apply KataConfig CR
- [ ] Wait for KataConfig to reach Ready state
- [ ] Verify kata runtime class: `oc get runtimeclass | grep kata`

**Step 3A.6: Trustee (KBS)**
- [ ] Install trustee-operator
- [ ] Apply kbs-config-cm ConfigMap
- [ ] Create auth key pair: `./trustee/create-attestation-token-secret.sh`
- [ ] Create KbsConfig CR
- [ ] Verify KBS pod is running: `oc get pods -n trustee-operator-system`

### Path B: AutoShift (ACM + ArgoCD)

Test the full GitOps pipeline.

- [ ] Verify ACM and ArgoCD are running
- [ ] Push `autoshiftv2-coco` branch to accessible git remote
- [ ] Apply clusterset labels to the managed cluster (from `hub-baremetal-sno-coco.yaml`)
- [ ] Wait for policies to propagate and become Compliant
- [ ] Verify each operator installed and configured

## Phase 4: PCCS Deployment (OpenShift Cluster)

Deploy PCCS on the cluster to serve attestation collateral.

- [ ] Transfer PCCS and Admin Tool images to the cluster
- [ ] Follow `intel-tdx-remote-attestation-disconnected/DEPLOYMENT-GUIDE.md` Option B
- [ ] Create intel-pccs namespace, PVC, Deployment, Service, Route
- [ ] Insert collateral via Admin Tool Job
- [ ] Verify PCCS is serving: `curl -k https://<pccs_route>/sgx/certification/v4/rootcacrl`

## Phase 5: Smoke Test

- [ ] Deploy a test pod with `kata-cc` runtime class:
  ```yaml
  apiVersion: v1
  kind: Pod
  metadata:
    name: coco-test
  spec:
    runtimeClassName: kata-cc
    containers:
      - name: test
        image: registry.access.redhat.com/ubi9/ubi:latest
        command: ["sleep", "infinity"]
  ```
- [ ] Verify pod is running: `oc get pod coco-test`
- [ ] Verify it's running in a TDX VM (if TDX hardware):
  ```bash
  oc exec coco-test -- cat /sys/kernel/tdx_guest/status
  ```
- [ ] Test KBS attestation flow (if Trustee is configured with reference values)
- [ ] Clean up: `oc delete pod coco-test`

## Phase 6: Record Results

- [ ] Update `CLAUDE.md` progress section with test results
- [ ] Note any CR schema mismatches (intel-tdx-dcap, intel-device-plugins)
- [ ] Note any operator version issues
- [ ] Document workarounds applied

## Rollback

If things go wrong, operators can be removed in reverse order:
1. Delete KataConfig (triggers node rollback — can take 10+ minutes)
2. Delete operator Subscriptions and CSVs
3. Delete MachineConfig (triggers another MCP rollout)
4. Remove CatalogSources if added

KataConfig deletion is the slowest step — it re-rolls nodes to remove the
kata runtime. Do NOT delete the sandboxed-containers operator before deleting
KataConfig, or the finalizer will hang.
