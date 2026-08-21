# Mirroring for Disconnected CoCo Deployment

This guide covers how to mirror all required container images, operator catalogs, and artifacts into a disconnected enclave for deploying OpenShift Confidential Containers on bare metal.

## What Gets Mirrored

The [`imageset-config.yaml`](../imageset-config.yaml) at the repository root captures everything:

| Category | Contents |
|----------|----------|
| OCP Platform | OpenShift release images (4.21.x) |
| Red Hat Operators | NFD, Sandboxed Containers, Trustee, Local Storage |
| Certified Operators | Intel Device Plugins, Intel TDX DCAP |
| Additional Images | dm-verity image, NFD operand, PCR collector, Intel QGS, CoCo tools |

## Prerequisites

- **oc-mirror v2** — version must match the target OCP release (4.21.x). Cross-version mismatches cause digest misalignment that breaks cluster installs.
- **Mirror registry** — a container registry running inside the disconnected enclave (e.g., `registry:2` with TLS and htpasswd auth)
- **Pull secret** — Red Hat pull secret from [console.redhat.com](https://console.redhat.com) merged with mirror registry credentials
- **Disk space** — approximately 50-80 GB for the oc-mirror workspace (varies with operator count)

## Mirror Registry Setup

If you do not already have a mirror registry, set one up on a host accessible from both the internet-connected side (for oc-mirror push) and the disconnected cluster nodes (for image pulls).

A minimal setup using the Docker `registry:2` container:

```bash
MIRROR_REGISTRY=<mirror-host>:8443

mkdir -p ~/mirror-registry-certs ~/mirror-registry-config ~/local-registry

# Generate self-signed TLS cert
openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:4096 \
  -keyout ~/mirror-registry-certs/server.key \
  -out ~/mirror-registry-certs/server.crt \
  -subj "/CN=${MIRROR_REGISTRY%%:*}"

# Generate htpasswd auth
htpasswd -Bbc ~/mirror-registry-config/htpasswd init "$(openssl rand -base64 18)"

# Start registry container
podman run -d --name mirror-registry \
  -p ${MIRROR_REGISTRY##*:}:8443 \
  -v ~/local-registry:/var/lib/registry:z \
  -v ~/mirror-registry-certs:/certs:z \
  -v ~/mirror-registry-config:/auth:z \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/server.key \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM=basic-realm \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -e REGISTRY_HTTP_ADDR=:8443 \
  docker.io/library/registry:2
```

Trust the registry CA for container tools:

```bash
mkdir -p ~/.config/containers/certs.d/${MIRROR_REGISTRY}
cp ~/mirror-registry-certs/server.crt ~/.config/containers/certs.d/${MIRROR_REGISTRY}/ca.crt
```

## Merge Pull Secret

Add mirror registry credentials to your Red Hat pull secret:

```bash
MREG_PASS=$(cat ~/mirror-registry-config/htpasswd | cut -d: -f2)

# Add mirror registry auth to pull-secret.json
oc registry login \
  --registry ${MIRROR_REGISTRY} \
  --auth-basic="init:${MREG_PASS}" \
  --to ~/pull-secret.json
```

Or manually:

```bash
python3 -c "
import json, base64, os
ps = json.load(open(os.path.expanduser('~/pull-secret.json')))
mreg = os.environ['MIRROR_REGISTRY']
mreg_pass = open(os.path.expanduser('~/mirror-registry-config/htpasswd')).read().split(':')[1].strip()
ps['auths'][mreg] = {
    'auth': base64.b64encode(f'init:{mreg_pass}'.encode()).decode(),
    'username': 'init',
    'password': mreg_pass
}
json.dump(ps, open(os.path.expanduser('~/pull-secret.json'), 'w'), indent=2)
print('Mirror registry auth added')
"
```

## Sigstore Skip Configuration

Intel, HashiCorp, and NVIDIA images on `registry.connect.redhat.com` lack cosign `.sig` manifests. Without this config, oc-mirror fails with `"name unknown: Image not found"`.

```bash
mkdir -p ~/.config/containers/registries.d
cat > ~/.config/containers/registries.d/no-sigstore-certified.yaml << 'EOF'
docker:
  registry.connect.redhat.com/intel:
    use-sigstore-attachments: false
  registry.connect.redhat.com/hashicorp:
    use-sigstore-attachments: false
  registry.connect.redhat.com/nvidia:
    use-sigstore-attachments: false
EOF
```

## Running oc-mirror

### Authenticate to the mirror registry

```bash
podman login ${MIRROR_REGISTRY} --username init --password "$(cat ~/mirror-registry-password)"
```

### Run the mirror

```bash
oc-mirror \
  --config imageset-config.yaml \
  docker://${MIRROR_REGISTRY} \
  --dest-tls-verify=true \
  --workspace file://$HOME/oc-mirror-workspace \
  --v2
```

This takes approximately 3-4 hours on first run depending on bandwidth. oc-mirror v2 is resumable — re-running the same command skips already-mirrored content.

### Common failures

| Failure | Cause | Fix |
|---------|-------|-----|
| `name unknown: Image not found` for Intel images | Missing sigstore skip config | Create `no-sigstore-certified.yaml` above |
| `context deadline exceeded` on large images | Network timeout on large blobs | Re-run the same oc-mirror command (resumes from cache) |
| Digest mismatch after cluster install | oc-mirror version doesn't match OCP version | Ensure oc-mirror binary is from the same OCP release |

## Post-Mirror Verification

After oc-mirror completes, verify the cluster-resources were generated:

```bash
# Check generated YAML files
ls ~/oc-mirror-workspace/working-dir/cluster-resources/
# Expected: IDMS, ITMS, CatalogSource, signature ConfigMaps (~10 files)

# Spot-check key repos in the mirror registry
for repo in \
  "openshift/release-images" \
  "openshift/release" \
  "openshift-sandboxed-containers/osc-operator-bundle" \
  "build-of-trustee/trustee-rhel9" \
  "redhat/redhat-operator-index" \
  "redhat/certified-operator-index"; do
  STATUS=$(curl -sk -u "init:${MREG_PASS}" \
    "https://${MIRROR_REGISTRY}/v2/${repo}/tags/list" | python3 -c \
    "import json,sys; print('OK' if json.load(sys.stdin).get('tags') else 'MISSING')" 2>/dev/null)
  echo "  ${STATUS}  ${repo}"
done
```

## Applying Cluster Resources

After the cluster is installed, apply the oc-mirror generated cluster resources to configure image content source policies:

```bash
# Apply all IDMS, ITMS, CatalogSources from oc-mirror output
oc apply -f ~/oc-mirror-workspace/working-dir/cluster-resources/

# Disable default OperatorHub catalogs (they point to the internet)
oc patch operatorhub cluster --type merge \
  -p '{"spec":{"disableAllDefaultSources":true}}'
```

## Non-Image Artifacts

Some artifacts needed for CoCo are not container images and must be transferred separately via sneakernet:

| Artifact | Source | Purpose |
|----------|--------|---------|
| `rekor.pub` | `tuf-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com/targets/rekor.pub` | Sigstore Rekor transparency log public key |
| `cosign-pub-key.pem` | `security.access.redhat.com/data/63405576.txt` | Red Hat container image cosign public key |
| `platform_collaterals.json` | Intel PCS via PCS Client Tool | PCK certificates and quote verification collateral |
| PCCS container images | Built from `intel-tdx-remote-attestation-disconnected/` | PCCS and Admin Tool for the enclave |

Fetch these on the internet-connected side and transfer to the enclave:

```bash
curl -L https://tuf-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com/targets/rekor.pub -o rekor.pub
curl -L https://security.access.redhat.com/data/63405576.txt -o cosign-pub-key.pem
```

## Updating the Mirror

When updating to a new OCP patch or operator version:

1. Update `imageset-config.yaml` with new version numbers
2. Ensure oc-mirror binary matches the new OCP version
3. Re-run `oc-mirror` — it only downloads delta content
4. Re-apply updated cluster-resources to the cluster
