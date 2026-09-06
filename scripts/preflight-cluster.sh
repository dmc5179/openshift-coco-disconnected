#!/bin/bash
# Pre-flight check: verify OpenShift cluster is ready for CoCo deployment
# Usage: ./preflight-cluster.sh
# Requires: oc CLI authenticated to the target cluster

set -euo pipefail

PASS=0
WARN=0
FAIL=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo "=== OpenShift CoCo Pre-Flight Check ==="
echo ""

# 1. Cluster connectivity
echo "--- Cluster Connectivity ---"
if oc whoami &>/dev/null; then
  USER=$(oc whoami)
  pass "Authenticated as: ${USER}"
else
  fail "Cannot authenticate to cluster"
  echo "Run: oc login <API_URL> -u kubeadmin -p <password>"
  exit 1
fi

API_URL=$(oc whoami --show-server)
pass "API server: ${API_URL}"

# 2. Cluster version
echo ""
echo "--- Cluster Version ---"
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
echo "  Cluster version: ${OCP_VERSION}"

MAJOR=$(echo "${OCP_VERSION}" | cut -d. -f1)
MINOR=$(echo "${OCP_VERSION}" | cut -d. -f2)
PATCH=$(echo "${OCP_VERSION}" | cut -d. -f3)

if [[ "${MAJOR}" -eq 4 && "${MINOR}" -ge 21 && "${PATCH}" -ge 9 ]]; then
  pass "Version ${OCP_VERSION} meets CoCo requirement (4.21.9+)"
elif [[ "${MAJOR}" -eq 4 && "${MINOR}" -gt 21 ]]; then
  pass "Version ${OCP_VERSION} meets CoCo requirement (4.21.9+)"
else
  fail "Version ${OCP_VERSION} does not meet CoCo requirement (4.21.9+)"
fi

# 3. FIPS mode
echo ""
echo "--- FIPS Mode ---"
FIPS_ENABLED=$(oc get cm -n openshift-config-managed fips-check -o jsonpath='{.data.enabled}' 2>/dev/null || echo "unknown")
if [[ "${FIPS_ENABLED}" == "true" ]]; then
  pass "FIPS mode is enabled"
elif [[ "${FIPS_ENABLED}" == "unknown" ]]; then
  # Alternative check via node
  NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
  FIPS_NODE=$(oc debug node/"${NODE}" -- chroot /host cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo "unknown")
  if [[ "${FIPS_NODE}" == "1" ]]; then
    pass "FIPS mode is enabled (verified via node)"
  else
    warn "Could not confirm FIPS mode"
  fi
else
  warn "FIPS mode is not enabled"
fi

# 4. Node count and roles
echo ""
echo "--- Nodes ---"
NODE_COUNT=$(oc get nodes --no-headers | wc -l)
MASTER_COUNT=$(oc get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | wc -l)
WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
echo "  Total: ${NODE_COUNT}, Masters: ${MASTER_COUNT}, Workers: ${WORKER_COUNT}"

if [[ "${NODE_COUNT}" -eq 1 ]]; then
  pass "Single-node OpenShift (SNO) detected"
elif [[ "${NODE_COUNT}" -ge 3 ]]; then
  pass "Multi-node cluster detected"
else
  warn "Unusual node count: ${NODE_COUNT}"
fi

# 5. TDX hardware detection
echo ""
echo "--- TDX Hardware ---"
TDX_NODES=$(oc get nodes -l intel.feature.node.kubernetes.io/tdx=true --no-headers 2>/dev/null | wc -l)
SGX_NODES=$(oc get nodes -l intel.feature.node.kubernetes.io/sgx=true --no-headers 2>/dev/null | wc -l)
if [[ "${TDX_NODES}" -gt 0 ]]; then
  pass "TDX nodes detected: ${TDX_NODES}"
else
  warn "No TDX-labeled nodes found (NFD may not be deployed yet)"
fi
if [[ "${SGX_NODES}" -gt 0 ]]; then
  pass "SGX nodes detected: ${SGX_NODES}"
else
  warn "No SGX-labeled nodes found (NFD may not be deployed yet)"
fi

# 6. Installed operators
echo ""
echo "--- Installed Operators ---"
check_operator() {
  local name=$1
  local display=$2
  if oc get csv -A 2>/dev/null | grep -q "${name}"; then
    CSV=$(oc get csv -A 2>/dev/null | grep "${name}" | head -1 | awk '{print $2, $NF}')
    pass "${display}: ${CSV}"
  else
    echo "  [----] ${display}: not installed"
  fi
}

check_operator "advanced-cluster-management" "ACM"
check_operator "openshift-gitops"            "OpenShift GitOps"
check_operator "nfd"                         "Node Feature Discovery"
check_operator "sandboxed-containers"        "Sandboxed Containers"
check_operator "trustee"                     "Trustee"
check_operator "intel-device-plugins"        "Intel Device Plugins"
check_operator "intel-tdx-dcap"              "Intel TDX DCAP"
check_operator "local-storage"               "Local Storage"
check_operator "lvms"                        "LVM Storage"

# 7. CatalogSources
echo ""
echo "--- CatalogSources ---"
oc get catalogsource -n openshift-marketplace --no-headers 2>/dev/null | while read -r name _; do
  echo "  [INFO] ${name}"
done

CERTIFIED=$(oc get catalogsource certified-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "missing")
if [[ "${CERTIFIED}" == "READY" ]]; then
  pass "certified-operators catalog is READY"
elif [[ "${CERTIFIED}" == "missing" ]]; then
  warn "certified-operators catalog not found (required for Intel operators)"
else
  warn "certified-operators catalog state: ${CERTIFIED}"
fi

# 8. Default StorageClass
echo ""
echo "--- Storage ---"
DEFAULT_SC=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)
if [[ -n "${DEFAULT_SC}" ]]; then
  pass "Default StorageClass: ${DEFAULT_SC}"
else
  warn "No default StorageClass found (needed for PCCS PVC, KBS storage)"
fi

# 9. MachineConfig for TDX
echo ""
echo "--- TDX MachineConfig ---"
TDX_MC=$(oc get mc 2>/dev/null | grep -i tdx | head -1 || true)
if [[ -n "${TDX_MC}" ]]; then
  pass "TDX MachineConfig found: $(echo "${TDX_MC}" | awk '{print $1}')"
else
  echo "  [----] No TDX MachineConfig found (will be applied during deployment)"
fi

# 10. KataConfig
echo ""
echo "--- KataConfig ---"
if oc get kataconfig 2>/dev/null | grep -q kataconfig; then
  KATA_STATUS=$(oc get kataconfig -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
  pass "KataConfig exists, Ready=${KATA_STATUS}"
else
  echo "  [----] No KataConfig found (will be created during deployment)"
fi

# Summary
echo ""
echo "=== Summary ==="
echo "  PASS: ${PASS}  WARN: ${WARN}  FAIL: ${FAIL}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo "Pre-flight FAILED — resolve failures before proceeding."
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo "Pre-flight passed with warnings — review before proceeding."
  exit 0
else
  echo "Pre-flight PASSED — cluster is ready for CoCo deployment."
  exit 0
fi
