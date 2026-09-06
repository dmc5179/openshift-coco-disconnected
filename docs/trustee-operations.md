# Trustee (KBS) Post-Deployment Operations

After the Trustee operator is deployed via AutoShift and the KbsConfig CR is
created, several operational tasks require manual steps. This document covers
RVPS reference values and KBS secret management.

## RVPS Reference Values

RVPS (Reference Value Provider Service) stores the expected TDX measurements
for the kata guest images in your OCP release. When a kata-cc pod starts in a
TDX VM, the attestation service compares the VM's actual measurements against
these reference values to verify integrity.

### Generating reference values

Use `scripts/generate-rvps-reference-values.sh` to compute reference values
from the kata guest images on your cluster:

```bash
# Requires: podman, oc logged into the cluster, pull secret for quay.io
./scripts/generate-rvps-reference-values.sh --pull-secret ~/.docker/config.json

# Or apply directly to the cluster
./scripts/generate-rvps-reference-values.sh --apply
```

The script uses the `veritas` tool from the `coco-tools` image to compute:

| Measurement | Description |
|-------------|-------------|
| `mr_td` | OVMF firmware hash |
| `rtmr_1` | Kernel and initrd measurements |
| `rtmr_2` | Kernel command line variants |
| `xfam` | Extended feature attribute mask |
| `tdvfkernel` | TDX virtual firmware kernel |
| `tdvfkernelparams` | TDX virtual firmware kernel parameters |

Output is a Kubernetes ConfigMap at `scripts/rvps-output/rvps-reference-values.yaml`.

### Applying reference values

```bash
# Apply the ConfigMap
oc apply -f scripts/rvps-output/rvps-reference-values.yaml

# Tell KBS to use it
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{"kbsRvpsRefValuesConfigMapName":"rvps-reference-values"}}'
```

The operator will reconcile and restart the KBS pod. Verify the reference
values are loaded:

```bash
KBS_POD=$(oc get pods -n trustee-operator-system -l app=kbs \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n trustee-operator-system "$KBS_POD" -c kbs -- \
  cat /opt/confidential-containers/storage/local_json/reference_value | \
  python3 -c "import sys,json,base64; data=json.load(sys.stdin); \
    [print(f'{k}: {len(json.loads(base64.b64decode(v))[\"value\"])} values') for k,v in data.items()]"
```

### When to regenerate

Regenerate reference values when:

- The OCP version changes (kata guest images change with each release)
- The sandboxed containers operator is upgraded
- You see attestation failures with "reference value mismatch" in KBS logs

## KBS Secret Management

KBS stores secrets that CoCo workloads can fetch during attestation. Secrets
are stored in the KBS pod's local filesystem and served to attested workloads
via the KBS resource API.

### Using kbs-secrets.sh

```bash
# Store a secret
./scripts/kbs-secrets.sh set my-app db-password 's3cret'

# Store a secret from a file
./scripts/kbs-secrets.sh set-file my-app tls-cert /path/to/cert.pem

# List all secrets
./scripts/kbs-secrets.sh list

# Retrieve a secret
./scripts/kbs-secrets.sh get my-app db-password

# Delete a secret
./scripts/kbs-secrets.sh delete my-app db-password

# Register the secret with the KbsConfig CR
./scripts/kbs-secrets.sh register my-app db-password
```

### How secrets work in CoCo

1. **Store secrets in KBS** using `kbs-secrets.sh set`. Secrets are stored
   at paths like `default/<repository>/<key>` in the KBS pod's filesystem.

2. **Register with KbsConfig CR** using `kbs-secrets.sh register`. This adds
   the Kubernetes Secret name to `kbsSecretResources` so the operator mounts
   it into the KBS pod.

3. **Fetch from CoCo workloads.** Inside a kata-cc pod, the CDH (Confidential
   Data Hub) retrieves secrets from KBS at `kbs:///default/<repository>/<key>`.
   The workload must have `cc_init_data` annotation configured to point CDH at
   the KBS URL.

### Secret path format

```
kbs:///default/<repository>/<key>
```

- `default` is the namespace (always "default" for standard deployments)
- `<repository>` groups related secrets (e.g., an app name)
- `<key>` is the individual secret name

### Important notes

- **Secrets are ephemeral** — they live in the KBS pod's `emptyDir` volume
  and are lost when the pod restarts. The operator re-populates them from
  Kubernetes Secrets listed in `kbsSecretResources`.
- **Do not edit the KBS ConfigMap directly** — the Trustee operator's
  reconcile loop will revert changes within seconds. Use the KbsConfig CR
  fields instead.
- **KBS pod label is `app=kbs`** (not `app=trustee-deployment`).

## Attestation Key Pair

The KBS requires an EC P-256 key pair for signing attestation tokens. The
operator does not auto-generate the `[attestation_token_broker.signer]`
section in the KBS TOML config.

### Generating keys (if needed)

```bash
# Generate EC P-256 private key
openssl ecparam -name prime256v1 -genkey -noout -out kbs-attest.key

# Generate self-signed certificate
openssl req -new -x509 -key kbs-attest.key -out kbs-attest.crt \
  -days 3650 -subj "/CN=KBS Attestation"

# Create Kubernetes secrets
oc create secret generic kbs-attestation-key \
  -n trustee-operator-system --from-file=key=kbs-attest.key
oc create secret generic kbs-attestation-cert \
  -n trustee-operator-system --from-file=cert=kbs-attest.crt

# Update KbsConfig CR
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{
    "kbsAttestationKeySecretName":"kbs-attestation-key",
    "kbsAttestationCertSecretName":"kbs-attestation-cert"
  }}'
```

**Must be EC (ES256), not RSA.** The attestation token broker expects an
ECDSA key on the NIST P-256 curve.

## Troubleshooting

### Checking KBS logs

```bash
KBS_POD=$(oc get pods -n trustee-operator-system -l app=kbs \
  -o jsonpath='{.items[0].metadata.name}')
oc logs -n trustee-operator-system "$KBS_POD" -c kbs -f
```

### Enable debug logging

```bash
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{"KbsEnvVars":{"RUST_LOG":"debug"}}}'
```

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "No reference value found" | RVPS reference values not loaded | Apply ConfigMap and set `kbsRvpsRefValuesConfigMapName` |
| Attestation token verification fails | EC key not configured or wrong format | Regenerate as EC P-256 (not RSA) |
| ConfigMap changes revert immediately | ACM ConfigurationPolicy enforcement | Edit in `autoshiftv2-coco/` git repo, not on cluster |
| KBS pod keeps restarting | operator v1.2 migration bug with `dir_path` | Delete and recreate KbsConfig CR |
| Kata-cc pod OOM killed | Insufficient memory for TDX VM | Set requests/limits to >= 4Gi |
