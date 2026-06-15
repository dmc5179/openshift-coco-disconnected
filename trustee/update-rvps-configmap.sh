#!/bin/bash

PULL_SECRET=/home/danclark/Downloads/pull-secret
CONTAINER_IMAGE=quay.io/openshift_sandboxed_containers/coco-tools:1.12
TEMP_DIR=/home/danclark/workspace/wf_rtx_coco/openshift-coco-disconnected/trustee/temp
TEE="tdx"
OCP_VERSION=$(oc version -o json | yq -r '.openshiftVersion' 2>/dev/null || echo "")

podman run \
    -v "${PULL_SECRET}:/pull-secret.json:ro,z" \
    -v "${TEMP_DIR}:/output:z" \
    "$CONTAINER_IMAGE" \
    veritas --platform baremetal --tee "$TEE" \
    --ocp-version "$OCP_VERSION" \
    --authfile /pull-secret.json \
    --hw-xfam-allow x87 --hw-xfam-allow sse --hw-xfam-allow avx \
    -o /output

oc apply -f "${TEMP_DIR}/rvps-reference-values.yaml"

