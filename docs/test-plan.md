# End-to-End Test Plan: CoCo on Disconnected Bare Metal

## Environment

| Component | Details |
|-----------|---------|
| Connected RHEL 9 | Internet-connected side. Builds attestation containers, fetches Intel collateral. |
| Disconnected RHEL 9 | Air-gap side. Runs mirror registry and PCCS. |
| OpenShift cluster | Target cluster. Bare metal, FIPS enabled, OCP 4.21.9+, Intel TDX CPUs. |
| Intel PCS key | Required for fetching attestation collateral. Free at [api.portal.trustedservices.intel.com](https://api.portal.trustedservices.intel.com/manage-subscriptions). |

## Pre-Deployment Checklist

- [ ] Cluster version is 4.21.9 or later
- [ ] FIPS mode is enabled: `oc get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'`
- [ ] Bare-metal nodes have Intel TDX-capable CPUs (4th Gen Xeon Scalable or newer)
- [ ] TDX enabled in BIOS (see [`docs/deployment-guide.md` Phase 1](deployment-guide.md#phase-1-configure-server-bios-for-tdx))
- [ ] SGX devices present: `ls /dev/sgx_*` on each node
- [ ] Mirror registry accessible (if disconnected)
- [ ] CatalogSources healthy: `oc get catalogsource -A`
- [ ] Pre-flight checks pass: `scripts/preflight-cluster.sh`, `scripts/preflight-rhel9.sh`

---

## Phase 1: Intel Attestation Infrastructure

Run on the connected RHEL server. Can run in parallel with Phase 2.

### 1.1 Build container images

- [ ] Clone `intel-tdx-remote-attestation-disconnected/`
- [ ] Build images: `./build.sh`
- [ ] Verify: `podman images | grep intel-tdx` (expect: pcs-client-tool, pccs-admin-tool, pccs)

### 1.2 Collect platform data

- [ ] On each TDX host: `sudo PCKIDRetrievalTool -f host_$(hostname -s).csv`
- [ ] Transfer all `host_*.csv` files to connected RHEL server

### 1.3 Fetch attestation collateral

```bash
cd intel-tdx-remote-attestation-disconnected
./scripts/fetch-platform-collateral.sh collect /path/to/csv-dir/
./scripts/fetch-platform-collateral.sh fetch --api-key YOUR_KEY
```

- [ ] `collateral-output/platform_list.json` created (check platform count)
- [ ] `collateral-output/platform_collaterals.json` created (expect ~500KB)

### 1.4 Deploy PCCS and insert collateral

```bash
./scripts/fetch-platform-collateral.sh insert https://pccs-host:8081 \
  --admin-token my-admin-token
```

- [ ] PCCS responds: `curl -sk https://pccs-host:8081/sgx/certification/v4/rootcacrl` returns data

---

## Phase 2: Image Mirroring (if disconnected)

- [ ] Run `oc-mirror` with `imageset-config.yaml` (see [`docs/mirroring.md`](mirroring.md))
- [ ] Transfer workspace to disconnected side
- [ ] Apply cluster resources: `oc apply -f cluster-resources/`
- [ ] Disable default catalogs: `oc patch operatorhub cluster --type merge -p '{"spec":{"disableAllDefaultSources":true}}'`
- [ ] Verify mirrored catalogs: `oc get catalogsource -A`

---

## Phase 3: Operator Deployment

Deploy via AutoShift or direct `oc apply`. See
[`AutoShift-CoCo-QuickStart.md`](../AutoShift-CoCo-QuickStart.md) for the
AutoShift path.

### 3.1 Verify all operators installed

```bash
oc get csv -A | grep -E 'sandboxed|trustee|nfd|intel|local-storage|lvms'
```

- [ ] Node Feature Discovery — installed and running
- [ ] Intel Device Plugins — installed, SgxDevicePlugin CR created
- [ ] Intel TDX DCAP — installed, QGS DaemonSet running
- [ ] Sandboxed Containers — installed, KataConfig ready
- [ ] Trustee — installed, KBS pod running

### 3.2 Verify hardware detection

```bash
oc get nodes -o json | jq '.items[].metadata.labels' | grep -E 'tdx|sgx|kata'
```

- [ ] `intel.feature.node.kubernetes.io/tdx` label present
- [ ] `intel.feature.node.kubernetes.io/sgx` label present
- [ ] `feature.node.kubernetes.io/runtime.kata` label present

### 3.3 Verify runtime class

```bash
oc get runtimeclass kata-cc
```

- [ ] `kata-cc` runtime class exists

### 3.4 Verify SGX resources

```bash
oc describe node | grep sgx.intel.com
```

- [ ] `sgx.intel.com/enclave` and `sgx.intel.com/provision` resources available

---

## Phase 4: Post-Deployment Configuration

### 4.1 Attestation key pair

```bash
openssl ecparam -name prime256v1 -genkey -noout -out kbs-attest.key
openssl req -new -x509 -key kbs-attest.key -out kbs-attest.crt \
  -days 3650 -subj "/CN=KBS Attestation"
oc create secret generic kbs-attestation-key \
  -n trustee-operator-system --from-file=key=kbs-attest.key
oc create secret generic kbs-attestation-cert \
  -n trustee-operator-system --from-file=cert=kbs-attest.crt
```

- [ ] Key is EC P-256 (not RSA): `openssl ec -in kbs-attest.key -text -noout | head -1`
- [ ] KbsConfig CR updated with key/cert secret names

### 4.2 RVPS reference values

```bash
./scripts/generate-rvps-reference-values.sh --apply
```

- [ ] ConfigMap `rvps-reference-values` created in `trustee-operator-system`
- [ ] KbsConfig CR updated: `kbsRvpsRefValuesConfigMapName: rvps-reference-values`
- [ ] KBS pod restarted and running

### 4.3 KBS QCNL configuration

- [ ] KBS can reach PCCS for quote verification collateral
- [ ] QCNL config mounted via `kbsLocalCertCacheSpec` or env var

---

## Phase 5: Smoke Tests

### 5.1 Basic kata-cc pod

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: coco-smoke-test
  annotations:
    io.katacontainers.config.hypervisor.default_memory: "4096"
spec:
  runtimeClassName: kata-cc
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "300"]
    resources:
      requests:
        memory: "4Gi"
      limits:
        memory: "4Gi"
  restartPolicy: Never
EOF
```

- [ ] Pod reaches Running state
- [ ] QEMU process shows `confidential-guest-support=tdx`
- [ ] Clean up: `oc delete pod coco-smoke-test`

### 5.2 CoCo policy enforcement

```bash
oc exec coco-smoke-test -- whoami
```

- [ ] `oc exec` is blocked (expected: error with ExecProcessRequest denied)

### 5.3 Full attestation with sealed secret

```bash
./scripts/kbs-secrets.sh set attestation-test test-value 'test-secret-123'
./scripts/kbs-secrets.sh register attestation-test test-value

INITDATA=$(./scripts/generate-initdata.sh debug)
sed "s|REPLACE_WITH_INITDATA|$INITDATA|" \
  testbed/workloads/coco-attestation-test.yaml | oc apply -f -
```

- [ ] Init container logs show `SUCCESS: attestation completed, secret retrieved`
- [ ] Result container shows `RESULT: PASS`
- [ ] KBS logs show successful auth → attest → resource flow
- [ ] Clean up: `oc delete pod coco-attestation-test`

### 5.4 Production-like deployment (httpd + route)

```bash
INITDATA=$(./scripts/generate-initdata.sh secure)
sed "s|REPLACE_WITH_INITDATA|$INITDATA|" \
  testbed/workloads/coco-sealed-httpd.yaml | oc apply -f -
```

- [ ] Deployment reaches 1/1 ready
- [ ] Route is accessible: `curl -sk https://coco-sealed-httpd-coco-test.apps.<cluster>/`
- [ ] Secret is served: `curl -sk https://coco-sealed-httpd-coco-test.apps.<cluster>/secret.txt`
- [ ] `oc exec` is blocked (secure policy)
- [ ] Clean up: `oc delete namespace coco-test`

---

## Phase 6: Feature Tests

### 6.1 Multiple sealed secrets

Test that a single pod can fetch multiple secrets from different KBS paths.

```bash
./scripts/kbs-secrets.sh set multi-test secret-one 'first-value'
./scripts/kbs-secrets.sh set multi-test secret-two 'second-value'
./scripts/kbs-secrets.sh set multi-test secret-three 'third-value'
./scripts/kbs-secrets.sh register multi-test secret-one
```

Deploy a pod that fetches all three via CDH:
- `http://127.0.0.1:8006/cdh/resource/default/multi-test/secret-one`
- `http://127.0.0.1:8006/cdh/resource/default/multi-test/secret-two`
- `http://127.0.0.1:8006/cdh/resource/default/multi-test/secret-three`

- [ ] All 3 secrets returned with correct values
- [ ] Attestation happens once, all fetches reuse the session
- [ ] Clean up secrets: `./scripts/kbs-secrets.sh delete multi-test secret-{one,two,three}`

### 6.2 Persistent volumes with kata-cc

Test that PVCs can be mounted in confidential containers.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: coco-pvc-test
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: coco-pvc-writer
  annotations:
    io.katacontainers.config.hypervisor.default_memory: "4096"
spec:
  runtimeClassName: kata-cc
  containers:
  - name: writer
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["/bin/bash", "-c", "echo 'persistent-data' > /data/test.txt && cat /data/test.txt"]
    volumeMounts:
    - name: data
      mountPath: /data
    resources:
      requests:
        memory: "4Gi"
      limits:
        memory: "4Gi"
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: coco-pvc-test
  restartPolicy: Never
EOF
```

- [ ] PVC binds successfully
- [ ] Pod writes data to the PVC
- [ ] Second pod reads data back from the same PVC
- [ ] Clean up: `oc delete pod coco-pvc-writer coco-pvc-reader; oc delete pvc coco-pvc-test`

### 6.3 OPA attestation policy

Check the default OPA policy and verify customization options.

```bash
KBS_POD=$(oc get pods -n trustee-operator-system -l app=kbs \
  -o jsonpath='{.items[0].metadata.name}')
oc exec -n trustee-operator-system "$KBS_POD" -c kbs -- \
  cat /opt/confidential-containers/opa/policy.rego
```

- [ ] Default policy documented (what fields it checks)
- [ ] KbsConfig CR has `kbsAttestationPolicyConfigMapName` field (or equivalent)
- [ ] Custom policy can be applied via CR (if supported)
- [ ] Attestation passes/fails based on custom policy rules

### 6.4 Encrypted container images (future)

Test pulling and running encrypted container images inside TDX VMs.

- [ ] Build encrypted image with `skopeo copy --encryption-key`
- [ ] Store decryption key in KBS
- [ ] Deploy kata-cc pod with encrypted image
- [ ] Container starts successfully (image decrypted after attestation)

### 6.5 Multi-node attestation

Verify attestation works across multiple TDX nodes (multi-node clusters only).

- [ ] Deploy a Deployment with `replicas: 2` and kata-cc runtime
- [ ] Pods schedule on different nodes
- [ ] Both pods complete attestation successfully
- [ ] KBS logs show distinct TDX quotes from each node

---

## Phase 7: Disconnected Validation

Test with no external network access.

### 7.1 Switch KBS QCNL to on-cluster PCCS

```bash
# Redeploy on-cluster PCCS with default tokens
helm upgrade pccs intel-tdx-remote-attestation-disconnected/chart/pccs/ \
  --namespace intel-pccs

# Insert collateral
./scripts/fetch-platform-collateral.sh insert \
  https://pccs.intel-pccs.svc.cluster.local:8081 --admin-token my-admin-token

# Update KBS QCNL to use on-cluster PCCS
# Edit kbs-qcnl-config secret to point pccs_url at
# https://pccs.intel-pccs.svc.cluster.local:8081
```

- [ ] On-cluster PCCS serves collateral
- [ ] KBS QCNL config updated
- [ ] KBS pod restarted

### 7.2 Test attestation without external network

- [ ] Block external network access (firewall rules or disconnect)
- [ ] Deploy kata-cc pod with sealed secret
- [ ] Attestation succeeds using only on-cluster resources
- [ ] Secret delivered successfully

---

## Rollback

If things go wrong, remove operators in reverse order:

1. Delete test workloads and namespaces
2. Delete KataConfig (triggers node rollback — 10+ minutes on bare metal)
3. Wait for MachineConfigPool to stabilize
4. Delete operator Subscriptions and CSVs
5. Delete MachineConfig (triggers another MCP rollout)
6. Remove CatalogSources if added

**Do NOT delete the sandboxed-containers operator before deleting KataConfig** —
the finalizer will hang indefinitely.

---

## Results Tracking

| Test | Status | Date | Notes |
|------|--------|------|-------|
| Basic kata-cc pod | | | |
| CoCo policy enforcement | | | |
| Full attestation (sealed secret) | | | |
| Production httpd deployment | | | |
| Multiple sealed secrets | | | |
| Persistent volumes | | | |
| OPA policy customization | | | |
| Encrypted images | | | |
| Multi-node attestation | | | |
| Disconnected validation | | | |
