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
- AutoShift policy: sandboxed-containers (operator-install + coco-config)
- AutoShift policy: trustee (operator-install + KbsConfig + ConfigMap)
- AutoShift policy: intel-device-plugins (operator-install + SgxDevicePlugin)
- AutoShift policy: intel-tdx-dcap (operator-install + QgsConfig)
- CoCo clusterset values: `hub-baremetal-sno-coco.yaml`
- `_example.yaml` updated with CoCo labels
- `intel-tdx-remote-attestation-disconnected/` docs updated (FIPS, CoreOS)

### Open Items
- NodeFeatureRule deployment — not yet in an AutoShift policy; currently a
  standalone YAML (`nfd-nodefeaturerule-combined.yaml`). May belong in the
  NFD policy or a new coco-infrastructure policy.
- MachineConfig for TDX kernel args — same situation as NodeFeatureRule.
  Needs a policy or integration into sandboxed-containers policy.
- Trustee post-deployment automation — auth key pair, RVPS reference values,
  and KBS repository secrets are manual steps. Scripts exist in `./trustee/`
  but aren't integrated into AutoShift.
- PCCS deployment on OpenShift — `intel-tdx-remote-attestation-disconnected/`
  has the guide, but no AutoShift policy for it (PCCS is not an OLM operator).
- QgsConfig CR — the `intel-tdx-dcap-operator` is in alpha channel; the CR
  API (`confidentialcontainers.intel.com/v1alpha1`) needs verification against
  the actual installed CRD.
- SgxDevicePlugin CR — needs verification of the API version and spec schema
  against the installed operator.
- End-to-end validation — none of the AutoShift policies have been tested on
  a live cluster yet.
- `./sandboxed_containers/` cleanup — directory is now redundant with AutoShift
  policies but hasn't been removed yet.
- `./trustee/` scripts — operational utilities (cert generation, RVPS updates)
  still live here. Not redundant, but need a better home or documentation.
