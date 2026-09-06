#!/bin/bash
set -euo pipefail

# Generate RVPS reference values for TDX attestation using the coco-tools
# veritas utility. This computes expected measurements (RTMR, MRTD, XFAM, etc.)
# from the kata guest images on the cluster.
#
# Prerequisites:
#   - podman available locally
#   - oc logged into the target cluster
#   - Pull secret with access to quay.io/openshift_sandboxed_containers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

COCO_TOOLS_IMAGE="${COCO_TOOLS_IMAGE:-quay.io/openshift_sandboxed_containers/coco-tools:1.12}"
PULL_SECRET="${PULL_SECRET:-$HOME/.docker/config.json}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/scripts/rvps-output}"
TEE="${TEE:-tdx}"
KBS_NAMESPACE="${KBS_NAMESPACE:-trustee-operator-system}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate RVPS reference values for CoCo TDX attestation.

Options:
  --pull-secret PATH     Path to pull secret (default: \$HOME/.docker/config.json)
  --output-dir PATH      Output directory (default: scripts/rvps-output/)
  --tee TYPE             TEE type: tdx or snp (default: tdx)
  --apply                Apply the generated ConfigMap to the cluster
  --dry-run              Show what would be generated without running
  -h, --help             Show this help

Environment variables:
  COCO_TOOLS_IMAGE       coco-tools container image (default: quay.io/openshift_sandboxed_containers/coco-tools:1.12)
  PULL_SECRET            Path to pull secret
  KBS_NAMESPACE          KBS namespace (default: trustee-operator-system)
EOF
    exit 0
}

APPLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull-secret) PULL_SECRET="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --tee) TEE="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ ! -f "$PULL_SECRET" ]]; then
    echo "ERROR: Pull secret not found at $PULL_SECRET"
    echo "Set PULL_SECRET or use --pull-secret to specify the path."
    exit 1
fi

OCP_VERSION=$(oc version -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion',''))" 2>/dev/null || echo "")
if [[ -z "$OCP_VERSION" ]]; then
    echo "ERROR: Could not determine OCP version. Are you logged into the cluster?"
    exit 1
fi
echo "Cluster OCP version: $OCP_VERSION"
echo "TEE type: $TEE"
echo "Output directory: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

if $DRY_RUN; then
    echo ""
    echo "Dry run — would execute:"
    echo "  podman run \\"
    echo "    -v ${PULL_SECRET}:/pull-secret.json:ro,z \\"
    echo "    -v ${OUTPUT_DIR}:/output:z \\"
    echo "    ${COCO_TOOLS_IMAGE} \\"
    echo "    veritas --platform baremetal --tee ${TEE} \\"
    echo "    --ocp-version ${OCP_VERSION} \\"
    echo "    --authfile /pull-secret.json \\"
    echo "    --hw-xfam-allow x87 --hw-xfam-allow sse --hw-xfam-allow avx \\"
    echo "    -o /output"
    exit 0
fi

echo ""
echo "Running veritas to compute reference values..."
podman run --rm \
    -v "${PULL_SECRET}:/pull-secret.json:ro,z" \
    -v "${OUTPUT_DIR}:/output:z" \
    "$COCO_TOOLS_IMAGE" \
    veritas --platform baremetal --tee "$TEE" \
    --ocp-version "$OCP_VERSION" \
    --authfile /pull-secret.json \
    --hw-xfam-allow x87 --hw-xfam-allow sse --hw-xfam-allow avx \
    -o /output

echo ""
echo "Generated files:"
ls -la "$OUTPUT_DIR/"

if [[ -f "$OUTPUT_DIR/rvps-reference-values.yaml" ]]; then
    echo ""
    echo "Reference values ConfigMap:"
    cat "$OUTPUT_DIR/rvps-reference-values.yaml"

    if $APPLY; then
        echo ""
        echo "Applying to cluster..."
        oc apply -f "$OUTPUT_DIR/rvps-reference-values.yaml"
        echo ""
        echo "Reference values applied. KBS will use these for attestation verification."
        echo "Restart the KBS pod to pick up the new values:"
        echo "  oc rollout restart deployment/trustee-deployment -n $KBS_NAMESPACE"
    else
        echo ""
        echo "To apply to the cluster:"
        echo "  oc apply -f $OUTPUT_DIR/rvps-reference-values.yaml"
        echo "  oc rollout restart deployment/trustee-deployment -n $KBS_NAMESPACE"
    fi
else
    echo ""
    echo "WARNING: rvps-reference-values.yaml not found in output."
    echo "Check the veritas output above for errors."
    exit 1
fi
