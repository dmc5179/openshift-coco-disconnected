#!/bin/bash -xe

SANDBOX_VERSION=$(oc get -n openshift-sandboxed-containers-operator -o json csv | jq -c -r '.items[0].spec.version')

echo "Version: $SANDBOX_VERSION"

# For disconnected environments, change this to your offline registry location
IMAGE="registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image:${SANDBOX_VERSION}"

echo "IMAGE: $IMAGE"

podman pull $IMAGE

cid=$(podman create --entrypoint /bin/true $IMAGE)
echo "CID: ${cid}"
podman cp $cid:/image/measurements.json measurements-raw.json
podman rm $cid

# Trim leading "0x" from all measurement values
jq 'walk(if type == "string" and startswith("0x") then .[2:] else . end)' \
    measurements-raw.json > measurements.json
