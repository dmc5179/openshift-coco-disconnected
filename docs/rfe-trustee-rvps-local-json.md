# RFE: Trustee Operator Should Configure RVPS local_json Store in AllInOneDeployment

## Component

- **Operator:** Red Hat build of Trustee (trustee-operator)
- **Version:** v1.2.1 (`trustee-operator.v1.2.1`)
- **Operator image:** `registry.redhat.io/build-of-trustee/trustee-rhel9-operator@sha256:193b4d79...`
- **KBS image:** `registry.redhat.io/build-of-trustee/trustee-rhel9@sha256:85312d29...`
- **KBS version:** v0.1.0
- **Upstream project:** [confidential-containers/trustee](https://github.com/confidential-containers/trustee) / [trustee-operator](https://github.com/confidential-containers/trustee-operator)

## Summary

When `kbsRvpsRefValuesConfigMapName` is set on the KbsConfig CR with
`kbsDeploymentType: AllInOneDeployment`, the operator correctly mounts the
reference values ConfigMap into the KBS pod but does not configure the RVPS
engine to read from it. The RVPS `local_json` field in the generated KBS TOML
config is always `None`, so RVPS uses an empty in-memory store and all reference
value lookups return null.

## Impact

RVPS reference value matching is silently skipped. Attestation succeeds based
solely on DCAP quote verification (signature, TCB status, collateral). This
means KBS cannot verify that the guest VM measurements (`mr_td`, `rtmr_1`,
`rtmr_2`, `xfam`, etc.) match expected values for the deployed OCP release.

A compromised or tampered kata guest image would still pass attestation as long
as the TDX DCAP quote is cryptographically valid and the TCB is up to date.
RVPS is the layer that catches measurement mismatches — without it, there is no
firmware/kernel integrity verification beyond what DCAP provides.

## Current Behavior

1. User creates a ConfigMap with reference values (e.g., from the `veritas` tool)
2. User sets `kbsRvpsRefValuesConfigMapName: rvps-reference-values` on the
   KbsConfig CR
3. Operator mounts the ConfigMap at
   `/opt/confidential-containers/storage/local_json/reference_value` with
   `subPath: reference_value` — **this is correct**
4. Operator generates KBS TOML with:
   ```toml
   [attestation_service.rvps_config]
   type = "BuiltIn"
   ```
   **Missing:** `local_json = "/opt/confidential-containers/storage/local_json/reference_value"`
5. RVPS starts with `local_json: None` (visible in debug logs)
6. During attestation, the Rego policy calls `query_reference_value("rtmr_1")`
   which returns null:
   ```
   WARN Regorus: attestation_service::ear_token::broker:
     No reference value found for the given id: rtmr_1, use NULL as the returned value
   ```
7. Attestation passes anyway because DCAP verification is independent of RVPS

## Expected Behavior

When `kbsRvpsRefValuesConfigMapName` is set, the operator should generate:

```toml
[attestation_service.rvps_config]
type = "BuiltIn"
local_json = "/opt/confidential-containers/storage/local_json/reference_value"
```

This would cause RVPS to load reference values at startup and make them
available to `query_reference_value()` in the attestation policy.

## Workarounds Attempted (All Failed)

1. **Manual ConfigMap edit** — Operator reconcile loop overwrites within seconds,
   stripping the `local_json` field before the KBS pod restarts.

2. **`kbsRvpsConfigMapName`** — Only applies to `MicroservicesDeployment`; has
   no effect in `AllInOneDeployment`. Pod did not restart.

3. **`kbsAsConfigMapName`** — Same: only applies to `MicroservicesDeployment`.
   TOML unchanged.

4. **RVPS admin API** — KBS does not expose an admin plugin
   (`PluginNotFound { plugin_name: "admin" }`). Only the `resource` plugin is
   configured in the generated TOML. Cannot provision reference values via REST.

No workaround exists for AllInOneDeployment without disabling the operator
reconcile loop entirely.

## Where to Fix

The operator's reconcile logic that generates the KBS TOML config needs a
one-line change. The code that writes the `[attestation_service.rvps_config]`
section should check whether `kbsRvpsRefValuesConfigMapName` is set, and if so,
include the `local_json` path:

```go
// Pseudo-code for the fix
if kbsConfig.Spec.KbsRvpsRefValuesConfigMapName != "" {
    rvpsConfig.LocalJson = "/opt/confidential-containers/storage/local_json/reference_value"
}
```

The volume mount is already correct — only the TOML generation needs updating.

Optionally, also enable the `admin` plugin in the generated TOML so that
reference values can be provisioned via the REST API as an alternative to
file-based loading:

```toml
[[plugins]]
name = "admin"
```

## Reproduction Steps

```bash
# 1. Deploy Trustee operator v1.2.1 with AllInOneDeployment
# 2. Create reference values ConfigMap
oc apply -f rvps-reference-values.yaml

# 3. Set kbsRvpsRefValuesConfigMapName
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{"kbsRvpsRefValuesConfigMapName":"rvps-reference-values"}}'

# 4. Wait for KBS pod to restart, then check
oc patch kbsconfig kbsconfig -n trustee-operator-system --type=merge \
  -p '{"spec":{"KbsEnvVars":{"RUST_LOG":"debug"}}}'

# 5. Observe in KBS logs:
#    rvps_config: BuiltIn { local_json: None, }
#    WARN: No reference value found for the given id: rtmr_1

# 6. Verify the file IS mounted (operator did the mount correctly):
KBS_POD=$(oc get pods -n trustee-operator-system -l app=kbs \
  -o jsonpath='{.items[0].metadata.name}')
oc exec -n trustee-operator-system "$KBS_POD" -c kbs -- \
  cat /opt/confidential-containers/storage/local_json/reference_value | head -c 200
# -> Returns valid JSON with reference values, but RVPS never reads it
```

## Environment

- OpenShift 4.22.6, bare metal, Intel TDX, FIPS enabled
- KataConfig with `kata-cc` runtime class, TDX confidential VMs
- Full attestation flow working (DCAP passes), but RVPS matching inactive
