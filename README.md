
## Intel Platform Registration for offline systems

Based on this doc: https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#on-offline-manual-multi-platform-pccs-based-indirect-registration
https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/02/infrastructure_setup/#on-offline-manual-multi-platform-local-cache-based-indirect-registration

## A subscription key for the Intel PCS

## The PCK Cert ID Retrieval Tool (PCKCIDRT) 

— A tool to support the retrieval of the PM and other platform information.

For Linux version:
- Install prebuilt Intel(R) SGX SDK , you can download it from [download.01.org](https://download.01.org/intel-sgx/latest/linux-latest/distro/)
    a. sgx_linux_x64_sdk_${version}.bin

## The PCCS Admin Tool  NOT NEEDED????

— A tool to facilitate manual retrieval of platform information from PCCS (if PCK Cert ID Retrieval Tool inserted it there) and insertion of registration collateral into PCCS.

## The PCS Client Tool

— A tool to facilitate registration collateral parsing and manual REST API communication with Intel® SGX and Intel® TDX Provisioning Certification Service for flows where PCCS is not present (or does not have a direct Internet connectivity). The tool provides helper functionality for Indirect Registration, PCK Certificate retrieval, and verification collateral retrieval especially in multi-platform environments.

- clone the tool in a connected environment and pull the modules
```
git clone https://github.com/intel/confidential-computing.tee.dcap.git
cd confidential-computing.tee.dcap/tools/PcsClientTool/
python3 -m pip download -r requirements.txt -d ./offline_modules
```

- Move the entire git repo over and install the modules from the directory copied
```
pip install --no-index --find-links=/path/to/local/dir -r requirements.txt
```
#### Things we might need offline

VERITY_IMAGE=registry.redhat.io/openshift-sandboxed-containers/osc-dm-verity-image

curl -L https://tuf-default.apps.rosa.rekor-prod.2jng.p3.openshiftapps.com/targets/rekor.pub -o rekor.pub
curl -L https://security.access.redhat.com/data/63405576.txt -o cosign-pub-key.pem




#############################

- Install LVMS operator for storage
- Install Sandboxed containers operator to get the kata runtime class
- Install NFD operator
- Install Vault????

```
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
spec:
  storage:
    deviceClasses:
    - name: vg1
      default: true
      deviceSelector:
        forceWipeDevicesAndDestroyAllData: true
        paths:
        - /dev/disk/by-path/pci-0000:9b:00.0-scsi-0:3:110:0
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        chunkSizeCalculationPolicy: Static
        metadataSizeCalculationPolicy: Host
        overprovisionRatio: 10
```


./scripts/gen-secrets.sh

vim ~/values-secret-coco-pattern.yaml

Enter Intel PCS API key


- Need to build the pcs-collector container for offline deployment

oc new-project pcr-collector

oc run pcr-collector --image=registry.access.redhat.com/ubi9/ubi:latest \
  --restart=Never --overrides='{"spec":{"runtimeClassName":"kata-cc"}}' \
  -- sleep 3600

oc exec pcr-collector -- dnf install -y tpm2-tools

  - From registry.access.redhat.com/ubi9/ubi:latest
  - dnf install -y tpm2-tools











