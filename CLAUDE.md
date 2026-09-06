# OpenShift Confidential Containers — Disconnected Deployment

## What This Is

A mono-repo orchestrating the deployment of OpenShift Confidential Containers
(CoCo) on bare-metal servers with Intel TDX in a fully disconnected (air-gapped)
enclave. FIPS is enabled. All operators deploy via AutoShift (ACM governance
policies through GitOps).

## Sub-Repositories

Three directories are **separate git repos** with their own branches and remotes:

| Directory | Repo | Role | Our changes? |
|-----------|------|------|-------------|
| `autoshiftv2-coco/` | AutoShift v2 fork | ACM policies for operator deployment via GitOps | Yes — `coco-disconnected` branch. CoCo policies + clusterset values |
| `intel-tdx-remote-attestation-disconnected/` | Intel TDX attestation | Containerized PCCS, PCS Client Tool, Admin Tool | Yes — `main` branch. FIPS/CoreOS docs |
| `coco-pattern/` | Validated Patterns | Ansible-based CoCo deployment (reference only) | **No — read-only reference.** We do NOT use Ansible validated patterns |
| `patterns-operator/` | Patterns operator | Validated patterns operator (reference only) | **No — read-only reference** |

When committing, commit to the correct repo. `git status` in the top-level repo
won't show changes inside sub-repos.

## Architecture

- **OCP 4.21.9+** required for CoCo GA on bare metal
- **FIPS enabled** — known concerns: kata guest kernel validation, Trustee TLS,
  PCCS Node.js (not FIPS-validated), dm-verity signing algorithms
- **Disconnected/air-gapped** — all images mirrored via oc-mirror v2,
  `disconnected-mirror: 'true'` label in AutoShift appends catalog suffix
- **Intel TDX TEE** — hardware attestation via PCCS + QGS + Trustee KBS

## Operator Stack (deployment order)

1. Node Feature Discovery (NFD) — detects TDX/SNP/SGX hardware
2. Intel Device Plugins — provides SGX device resources
3. Intel TDX DCAP — manages QGS (Quote Generation Service)
4. OpenShift Sandboxed Containers — CoCo runtime (KataConfig + feature gates)
5. Trustee — KBS for attestation and secret delivery
6. Local Storage — persistent storage for KBS

## Key Files

| File | Purpose |
|------|---------|
| `imageset-config.yaml` | Consolidated oc-mirror v2 config (all operators + images) |
| `docs/mirroring.md` | Disconnected mirroring guide |
| `docs/intel-infrastructure.md` | Internet-connected side Intel TDX setup |
| `nfd-nodefeaturerule-combined.yaml` | Canonical NFD rule (TDX, SNP, SGX, kata detection) |
| `kataconfig-cr.yaml` | KataConfig reference CR |
| `machine-config-intel-tdx.yaml` | MachineConfig for TDX kernel args |
| `osc-feature-gates.yaml` | Feature gates ConfigMap (confidential mode) |

## AutoShift Policies (in `autoshiftv2-coco/`)

| Policy directory | Cluster label | Status |
|-----------------|---------------|--------|
| `policies/stable/sandboxed-containers/` | `autoshift.io/sandboxed-containers: 'true'` | Created |
| `policies/stable/trustee/` | `autoshift.io/trustee: 'true'` | Created |
| `policies/stable/intel-device-plugins/` | `autoshift.io/intel-device-plugins: 'true'` | Created |
| `policies/stable/intel-tdx-dcap/` | `autoshift.io/intel-tdx-dcap: 'true'` | Created |
| `policies/stable/node-feature-discovery/` | `autoshift.io/node-feature-discovery: 'true'` | Pre-existing (upstream) |

CoCo clusterset profile: `autoshift/values/clustersets/hub-baremetal-sno-coco.yaml`

## AutoShift Conventions

- Policies use the shared `components/operator-install` Helm chart
- Hub template syntax: `{{hub ... hub}}` for dynamic label lookups
- Disconnected mirror: `disconnected-mirror: 'true'` label appends `-mirror`
  suffix to CatalogSource names
- Operator labels follow: `{name}: 'true'`, `{name}-subscription-name`,
  `{name}-channel`, `{name}-source`, `{name}-source-namespace`, `{name}-version`
- PolicyGenerator config uses `${REMEDIATION}`, `${POLICY_NAMESPACE}`,
  `${EVAL_COMPLIANT}`, `${EVAL_NONCOMPLIANT}` — substituted by ArgoCD CMP
  before `kustomize build`

## What NOT to Do

- Do NOT follow the coco-pattern Ansible approach — we use AutoShift
- Do NOT modify `coco-pattern/` or `patterns-operator/` — reference only
- Do NOT hardcode image digests in AutoShift policies — use operator-managed images
- Do NOT commit secrets, TLS keys, or Intel PCS API keys

## Progress

### Completed
- Consolidated `imageset-config.yaml` (all operators + additional images)
- Top-level `README.md` with architecture and deployment order
- `docs/mirroring.md` — disconnected mirroring guide
- `docs/intel-infrastructure.md` — internet-connected side Intel setup
- AutoShift policy: sandboxed-containers (operator-install + tdx-machine-config + coco-config)
- AutoShift policy: trustee (operator-install + KbsConfig + ConfigMap, v0.1.0 schema)
- AutoShift policy: intel-device-plugins (operator-install + SgxDevicePlugin)
- AutoShift policy: intel-tdx-dcap (operator-install + TdxQuoteGenerationService)
- CoCo clusterset values: `hub-baremetal-sno-coco.yaml`
- `_example.yaml` updated with CoCo labels
- `intel-tdx-remote-attestation-disconnected/` docs updated (FIPS, CoreOS)
- Pre-flight scripts: `scripts/preflight-cluster.sh`, `scripts/preflight-rhel9.sh`
- End-to-end test plan: `docs/test-plan.md`
- AutoShift NFD policy: added CoCo NodeFeatureRule (TDX, SNP, SGX, kata detection)
- PCCS Helm chart: `intel-tdx-remote-attestation-disconnected/chart/pccs/`
- KBS config verified against Trustee v0.1.0 schema (5 iterations)
- E2E CoCo validation: test pod running in TDX VM with CoCo policy enforcement
- QgsConfig CR verified: `trustedservices.intel.com/v1 TdxQuoteGenerationService`
- SgxDevicePlugin CR verified: `deviceplugin.intel.com/v1`
- RVPS reference values: `scripts/generate-rvps-reference-values.sh` generates
  TDX measurements via veritas tool. Applied to cluster via KbsConfig CR
  `kbsRvpsRefValuesConfigMapName` field.
- KBS secrets helper: `scripts/kbs-secrets.sh` manages KBS repository secrets
  (set/get/list/delete/register commands)
- vsock-proxy DaemonSet: integrated into intel-tdx-dcap AutoShift policy

### Open Items
- ~~NodeFeatureRule deployment~~ — DONE. Integrated into the NFD policy as
  `coco-nodefeaturerule` manifest group (detects TDX, SNP, SGX, kata hardware).
- ~~MachineConfig for TDX kernel args~~ — DONE. Integrated into
  sandboxed-containers policy as `tdx-machine-config` manifest group.
- ~~Trustee token signing/verification~~ — DONE. KBS TOML requires
  `[attestation_service.attestation_token_broker.signer]` with `key_path` and
  `cert_path` pointing to the mounted EC (P-256) key/cert. Operator v1.2.1
  doesn't generate this section automatically — fixed in AutoShift policy
  `trustee-config/kbs-config-cm.yaml`. Attestation key must be EC, not RSA.
- Trustee post-deployment automation — RVPS reference values automated via
  `scripts/generate-rvps-reference-values.sh`. KBS secrets managed via
  `scripts/kbs-secrets.sh`. Both applied to cluster and verified.
- ~~PCCS deployment on OpenShift~~ — DONE. Helm chart at
  `intel-tdx-remote-attestation-disconnected/chart/pccs/`.
- ~~QgsConfig CR~~ — DONE. Actual CRD is `trustedservices.intel.com/v1
  TdxQuoteGenerationService` (singleton name `intel-tdx-dcap`).
- ~~SgxDevicePlugin CR~~ — DONE. Verified `deviceplugin.intel.com/v1`.
- ~~End-to-end validation~~ — DONE. Test pod running in TDX VM with kata-cc
  runtime class. CoCo policy enforcement confirmed (`oc exec` blocked).
  QEMU uses `confidential-guest-support=tdx` with `OVMF.inteltdx.fd`.
- `./sandboxed_containers/` cleanup — directory is now redundant with AutoShift
  policies but hasn't been removed yet.
- `./trustee/` scripts — operational utilities (cert generation, RVPS updates)
  still live here. Not redundant, but need a better home or documentation.
- Intel TDX attestation infrastructure testing — CRL collateral fetched from
  Intel PCS and inserted into PCCS via REST API. PCCS serves CRL data. Full
  platform collateral flow requires real TDX hardware CSV files (collect ->
  fetch -> insert). EC2 host: `ec2-98-91-225-77.compute-1.amazonaws.com`
  (public: `98.91.225.77`).
- Firewall requirements for OpenShift -> PCCS connectivity:
  - AWS Security Group: open TCP 8081 inbound from OCP egress IP `66.187.232.140`
  - Security Groups: `sg-0b0f6887b1df6f95f`, `sg-0e218d7cfa5323350`
  - PCCS must run with `--network host` (rootless podman only binds localhost)
- SgxDevicePlugin: `enclaveLimit` and `provisionLimit` must be >= 10 for the
  QGS DaemonSet to schedule (it has 3 containers each requesting SGX resources).
- Intel TDX DCAP: QGS service account needs `privileged` SCC (hostPath volumes,
  runAsUser: 0, spc_t SELinux type).
- Kata-cc pods: require >= 4Gi memory (TDX VM uses 2048M; 256Mi causes OOM kill).
- KBS config: operator controls ConfigMap via reconcile loop — do NOT edit
  ConfigMap directly; changes are reverted. Use KbsConfig CR fields instead.
- KBS `dir_path` migration bug: operator v1.2 migration from v1.1 sets wrong
  storage path. Deleting and recreating KbsConfig CR generates correct v1.2 TOML.
- KBS attestation secrets (`kbs-attestation-key`, `kbs-attestation-cert`) contain
  EC P-256 key/cert generated 2026-09-05. These are cluster-only — not in git.
  If deleted, regenerate: `openssl ecparam -name prime256v1 -genkey -noout`,
  then self-signed cert. Must be EC (ES256), not RSA.
- ACM ConfigurationPolicy enforcement: `kbs-config-cm` ConfigMap is managed by
  `policy-trustee-config` in `local-cluster` namespace. Manual edits revert
  within seconds. Changes must go through `autoshiftv2-coco/` git repo.
- `qgs-vsock-proxy` DaemonSet in `intel-dcap` namespace — socat bridge from
  vsock port 4050 to QGS Unix socket. Integrated into intel-tdx-dcap AutoShift
  policy as `vsock-proxy` manifest group. Uses host's `/usr/bin/socat` mounted
  into UBI9 container (disconnected-safe, no dnf install needed). Tested:
  full attestation flow works with DaemonSet proxy.
- PCCS on cluster (`intel-pccs` namespace): NodePort 30081, ClusterIP
  172.30.144.185:8081. Has no cached collateral (404 on rootcacrl) — but
  this is not blocking QGS because the operator uses a different mechanism.
- QGS QCNL config: operator overrides via pod annotation `qcnl-conf` with
  `{"local_cache_only": true}`. QGS reads PCK certs from `/run/dcap/cache/`
  populated by the `pck-cert-tool` sidecar. The default `/etc/sgx_default_qcnl.conf`
  (localhost:8081) is NOT used. PCK cert secrets (`-pck` suffixed) are created
  by the registrar after fetching from Intel PCS.
- DCAP operator PCK cert flow: initContainer collects platform manifest →
  creates K8s secret → registrar watches for platform secrets → fetches PCK
  certs from Intel PCS → creates `-pck` secret → sidecar writes to cache.
  Platform secrets: `052ee8ba6f37c01369058c914b2bfd09` (23KB cache),
  `40d0ab17d57614709b7d60174d7a7943`. Third secret `64dc40cfaa5f0ff4c714657ede203559`
  has "Missing platform_manifest field" (stale or incomplete).
- EC2 PCCS host (`98.91.225.77`): unreachable as of 2026-09-06 (SSH and
  HTTPS both timeout). May need AWS security group fix or instance restart.
