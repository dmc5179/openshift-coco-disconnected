#!/bin/bash
# Pre-flight check: verify RHEL 9 VM is ready for Intel attestation infrastructure
# Usage: ./preflight-rhel9.sh
# Run on the RHEL 9 VM (internet-connected side)

set -euo pipefail

PASS=0
WARN=0
FAIL=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo "=== RHEL 9 Intel Attestation Pre-Flight Check ==="
echo ""

# 1. OS version
echo "--- Operating System ---"
if [ -f /etc/redhat-release ]; then
  OS=$(cat /etc/redhat-release)
  pass "OS: ${OS}"
else
  fail "Not a Red Hat system"
fi

# 2. Podman
echo ""
echo "--- Container Runtime ---"
if command -v podman &>/dev/null; then
  PODMAN_VER=$(podman --version)
  pass "Podman: ${PODMAN_VER}"
else
  fail "Podman is not installed"
  echo "  Run: sudo dnf install -y podman"
fi

# 3. Git
echo ""
echo "--- Git ---"
if command -v git &>/dev/null; then
  GIT_VER=$(git --version)
  pass "Git: ${GIT_VER}"
else
  fail "Git is not installed"
  echo "  Run: sudo dnf install -y git"
fi

# 4. Python 3
echo ""
echo "--- Python ---"
if command -v python3 &>/dev/null; then
  PY_VER=$(python3 --version)
  pass "Python: ${PY_VER}"
else
  warn "Python 3 not found (needed for PCS Client Tool if running outside container)"
fi

# 5. oc CLI
echo ""
echo "--- OpenShift CLI ---"
if command -v oc &>/dev/null; then
  OC_VER=$(oc version --client 2>/dev/null | head -1)
  pass "oc CLI: ${OC_VER}"
else
  warn "oc CLI not installed (needed to interact with OpenShift cluster)"
  echo "  Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
fi

# 6. Internet connectivity
echo ""
echo "--- Internet Connectivity ---"
if curl -sf --connect-timeout 5 https://registry.redhat.io/v2/ &>/dev/null; then
  pass "Can reach registry.redhat.io"
else
  warn "Cannot reach registry.redhat.io"
fi

if curl -sf --connect-timeout 5 https://api.trustedservices.intel.com &>/dev/null; then
  pass "Can reach Intel PCS (api.trustedservices.intel.com)"
else
  warn "Cannot reach Intel PCS"
fi

if curl -sf --connect-timeout 5 https://github.com &>/dev/null; then
  pass "Can reach github.com (for intel-tdx repo clone)"
else
  warn "Cannot reach github.com"
fi

# 7. Disk space
echo ""
echo "--- Disk Space ---"
AVAIL=$(df -BG --output=avail / | tail -1 | tr -d ' G')
if [[ "${AVAIL}" -ge 50 ]]; then
  pass "Root filesystem: ${AVAIL}G available"
elif [[ "${AVAIL}" -ge 20 ]]; then
  warn "Root filesystem: ${AVAIL}G available (50G+ recommended for container builds)"
else
  fail "Root filesystem: ${AVAIL}G available (insufficient — need 20G minimum)"
fi

# 8. SELinux
echo ""
echo "--- SELinux ---"
SE_STATUS=$(getenforce 2>/dev/null || echo "unknown")
if [[ "${SE_STATUS}" == "Enforcing" ]]; then
  pass "SELinux: Enforcing"
elif [[ "${SE_STATUS}" == "Permissive" ]]; then
  warn "SELinux: Permissive (Enforcing recommended)"
else
  warn "SELinux status: ${SE_STATUS}"
fi

# 9. Existing attestation artifacts
echo ""
echo "--- Existing Artifacts ---"
if [ -d ./intel-tdx-remote-attestation-disconnected ]; then
  pass "intel-tdx-remote-attestation-disconnected repo found"
else
  echo "  [----] intel-tdx-remote-attestation-disconnected repo not cloned yet"
fi

if [ -d ./images ]; then
  echo "  [INFO] Existing image tarballs:"
  ls -lh ./images/*.tar 2>/dev/null | awk '{print "         " $NF " (" $5 ")"}'
else
  echo "  [----] No image tarballs directory"
fi

if ls ./platform-data/host_*.csv &>/dev/null; then
  CSV_COUNT=$(ls ./platform-data/host_*.csv | wc -l)
  pass "Platform CSV files found: ${CSV_COUNT}"
else
  echo "  [----] No platform CSV files found (will collect from TDX hosts)"
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
  echo "Pre-flight PASSED — VM is ready for attestation infrastructure setup."
  exit 0
fi
