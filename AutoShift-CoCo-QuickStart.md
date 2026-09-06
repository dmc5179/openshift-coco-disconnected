# Deploying CoCo via AutoShift — Quick Start

Install ACM, GitOps, and AutoShift on your hub cluster, which then deploys the
full Confidential Containers operator stack via ACM governance policies:

| Order | Operator | Purpose |
|-------|----------|---------|
| 1 | Node Feature Discovery (NFD) | Detects TDX/SNP/SGX hardware |
| 2 | Intel Device Plugins | Provides SGX device resources |
| 3 | Intel TDX DCAP | Manages QGS (Quote Generation Service) |
| 4 | OpenShift Sandboxed Containers | CoCo runtime (KataConfig + feature gates) |
| 5 | Trustee | KBS for attestation and secret delivery |
| 6 | Local Storage | Persistent storage for KBS |
| 7 | LVM Storage | Default StorageClass for SNO |

## Prerequisites

- OCP 4.21.9+ bare-metal cluster with Intel TDX-capable hardware
- FIPS enabled
- `oc` and `helm` CLIs installed
- Images already mirrored to your disconnected registry (see `docs/mirroring.md`
  and `imageset-config.yaml`)
- A fork/clone of this repository pushed somewhere your cluster can reach (e.g.
  a Git server inside the enclave)

## Step 1: Login to the hub cluster

```bash
oc login --token=sha256~... --server=https://api.your-cluster.example.com:6443
```

## Step 2: Customize the CoCo clusterset values

Copy the CoCo values template and edit it for your environment:

```bash
cp autoshiftv2-coco/autoshift/values/clustersets/hub-baremetal-sno-coco.yaml \
   autoshiftv2-coco/autoshift/values/clustersets/my-coco.yaml
```

Edit `my-coco.yaml`. Values you likely need to change:

| Value | What to set | Default |
|-------|-------------|---------|
| `openshift-version` | Your OCP version (e.g. `4.21.15`) | `4.21.15` |
| `disconnected-mirror` | `'true'` (already set) | `'true'` |
| `mirror-catalog-suffix` | Suffix appended to CatalogSource names | `'mirror'` |
| `lvm-channel` | Match your OCP version (e.g. `stable-4.21`) | `stable-4.21` |
| `metallb-ippool-1` | Your MetalLB IP pool range, or set `metallb: 'false'` to disable | `''` |
| `acm-channel` | Your ACM version channel | `release-2.17` |

If your mirror registry uses non-standard catalog source names, verify the
`-source` labels for each operator point to the correct mirrored catalog.

## Step 3: Update global.yaml to point at your fork

Edit `autoshiftv2-coco/autoshift/values/global.yaml`:

```yaml
autoshiftGitRepo: https://github.com/dmc5179/autoshiftv2.git   # your fork
autoshiftGitBranchTag: coco-disconnected                         # your branch
```

## Step 4: Install ACM and GitOps

You have two options: use the AutoShift helm bootstrap charts, or install the
operators directly via OLM. Pick one.

### Option A: Helm bootstrap (recommended by AutoShift docs)

Run from the `autoshiftv2-coco/` directory:

```bash
cd autoshiftv2-coco

# Install ACM
helm upgrade --install advanced-cluster-management advanced-cluster-management

# Wait for ACM operator deployment
oc get deploy multicluster-operators-hub-subscription -n open-cluster-management -w

# Install GitOps
helm upgrade --install openshift-gitops openshift-gitops \
  -f policies/stable/openshift-gitops/values.yaml
```

> **Note:** If your cluster does not have the internal image registry enabled
> (common on bare metal), add `--set image=<your-mirror>/openshift4/ose-cli:latest`
> to both helm commands. The bootstrap charts run a CRD-wait Job that pulls
> `image-registry.openshift-image-registry.svc:5000/openshift/cli:latest` by
> default, which will fail with `ImagePullBackOff` if the registry is disabled.

### Option B: Direct OLM install (no helm for bootstrap)

**Install ACM:**

```bash
oc create namespace open-cluster-management || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
EOF

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.17
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for the operator
oc wait --for=condition=Available deploy/multicluster-operators-hub-subscription \
  -n open-cluster-management --timeout=10m

# Create the MultiClusterHub
oc apply -f - <<'EOF'
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
```

**Install GitOps:**

```bash
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: gitops-1.21
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
  config:
    env:
      - name: DISABLE_DEFAULT_ARGOCD_INSTANCE
        value: 'true'
EOF
```

> **Note for Option B:** The helm chart for GitOps also creates the
> `infra-gitops` ArgoCD CR with the PolicyGenerator CMP sidecar, resource
> limits, and RBAC. If you skip helm, AutoShift's own `openshift-gitops` policy
> will create this ArgoCD instance once policies start reconciling.
>
> For disconnected environments, change `source: redhat-operators` to whatever
> your mirrored CatalogSource is named (e.g. `redhat-operators-mirror`).

## Step 5: Wait for ACM and GitOps to be ready

```bash
# ACM — wait for MultiClusterHub to reach Running (~10 min)
oc get mch -A -w

# GitOps — wait for pods
oc get pods -n openshift-gitops -w

# Verify the ArgoCD instance exists
oc get argocd -A
```

## Step 6: Install AutoShift

Run from the `autoshiftv2-coco/` directory. This uses helm's dev mode (direct
install from your local working copy — no ArgoCD Application needed for the
initial bootstrap):

```bash
cd autoshiftv2-coco

helm upgrade --install autoshift ./autoshift \
  -n openshift-gitops \
  -f autoshift/values/global.yaml \
  -f autoshift/values/clustersets/my-coco.yaml
```

> **Tip:** To iterate on values, edit `my-coco.yaml` and re-run the same
> `helm upgrade` command. Changes take effect immediately without a
> commit/push/ArgoCD sync cycle.
>
> For production, replace this step with an ArgoCD Application pointing at your
> Git repo. See the AutoShift `docs/quickstart.md` Step 4 for the full
> Application manifest.

## Step 7: Assign the hub cluster to the clusterset

```bash
oc label managedcluster local-cluster \
  cluster.open-cluster-management.io/clusterset=hub --overwrite
```

## Step 8: Verify

```bash
# AutoShift ApplicationSet and generated Applications
oc get applicationset autoshift-policies -n openshift-gitops
oc get applications.argoproj.io -n openshift-gitops | grep autoshift

# ACM policies created and compliance status
oc get policies -A

# Watch operators install
oc get csv -A | grep -E 'sandboxed|trustee|intel|nfd|local-storage|lvms'

# Verify CoCo-specific CRs once operators are ready
oc get kataconfig -A
oc get kbsconfig -A
oc get sgxdeviceplugin -A
```

## What you customized (summary)

| File | What to change |
|------|----------------|
| `autoshift/values/clustersets/my-coco.yaml` | OCP version, mirror settings, operator channels/sources for your mirrored catalogs |
| `autoshift/values/global.yaml` | `autoshiftGitRepo` and `autoshiftGitBranchTag` — point at your fork/branch |
| ACM/GitOps Subscriptions (Option B only) | `source` field — your mirrored CatalogSource name |
| Helm bootstrap (Option A only) | `--set image=...` if no internal image registry |

Everything else — which operators to install, KataConfig, Trustee KbsConfig,
SgxDevicePlugin, QgsConfig, feature gates — is already baked into the AutoShift
policies on the `coco-disconnected` branch.

## Post-deployment (manual steps)

These are not yet automated via AutoShift policies:

1. **Trustee auth key pair** — generate and upload to the KBS
2. **RVPS reference values** — register expected TDX measurements
3. **KBS repository secrets** — configure secrets for workload delivery
4. **PCCS setup** — see `intel-tdx-remote-attestation-disconnected/` for the
   containerized PCCS deployment guide (PCCS is not an OLM operator)

See `trustee/` for operational scripts and `docs/test-plan.md` for end-to-end
validation steps.

## Troubleshooting

```bash
# Policies not applying — check cluster labels
oc get managedcluster local-cluster --show-labels

# Check placement
oc get placement -n open-cluster-policies

# Policy details
oc describe policy <policy-name> -n open-cluster-policies

# ArgoCD sync issues
oc get applications.argoproj.io -n openshift-gitops -o wide
oc describe application.argoproj.io <app-name> -n openshift-gitops

# GitOps pod issues
oc get events -n openshift-gitops --sort-by=.lastTimestamp
```
