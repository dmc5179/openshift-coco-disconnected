# OCP CoCo Bare Metal

- Must use OCP 4.21.9 or greater

## Intel Platform Registration for offline systems

- Refer to my other repo to deploy the Intel Infrastructure for disconnected CoCo here:

https://github.com/dmc5179/intel-tdx-remote-attestation-disconnected

- Create a tdx-machine-config.yaml manifest file according to the following example:

oc create -f  machine-config-intel-tdx.yaml

## Things we might need offline

- Notes of random things that will need to be moved into the disconnected environment

```
VERITY_IMAGE=registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image

curl -L https://tuf-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com/targets/rekor.pub -o rekor.pub
curl -L https://security.access.redhat.com/data/63405576.txt -o cosign-pub-key.pem
```

## Cluster Setup for CoCo

- Install LVMS operator for storage #OCP SNOW Only

```console
oc create -f sno-lvm-cluster-cr.yaml
```


## Install NFD Operator

## Install Sandboxed containers operator to get the kata runtime class

https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.12/html/deploying_openshift_sandboxed_containers_on_bare-metal_servers/install-osc-overview_metal-osc#installing-osc-operator_metal-osc

- optional config maps I have not explored
config map: osc-feature-gates.yaml
config map: kata-addon-artifacts

## Install Vault

- Can possibly use kube secrets without vault maybe??

## Install the Trustee Operator

## CoCo Install and configure # Below here is still in work

- Currently using this repo but instead of ArgoCD it uses Ansible validated patterns

https://github.com/validatedpatterns/coco-pattern

./scripts/gen-secrets.sh

vim ~/values-secret-coco-pattern.yaml

Enter Intel PCS API key

- Need to build the pcs-collector container for offline deployment

oc new-project pcr-collector

# Use mine for offline builds
# quay.io/danclark/pcr-collector:latest

#oc run pcr-collector --image=registry.access.redhat.com/ubi9/ubi:latest \
#  --restart=Never --overrides='{"spec":{"runtimeClassName":"kata-cc"}}' \
#  -- sleep 3600

oc run pcr-collector --image=quay.io/danclark/pcr-collector:latest \
  --restart=Never --overrides='{"spec":{"runtimeClassName":"kata-cc"}}' \
  -- sleep 3600


oc exec pcr-collector -- tpm2_pcrread sha256:3,9,11,12

oc delete pod pcr-collector

