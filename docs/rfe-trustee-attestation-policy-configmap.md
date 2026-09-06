# RFE: Trustee Operator Deletes User-Provided Attestation Policy ConfigMap

## Component

- **Operator:** Red Hat build of Trustee (trustee-operator)
- **Version:** v1.2.1 (`trustee-operator.v1.2.1`)
- **Operator image:** `registry.redhat.io/build-of-trustee/trustee-rhel9-operator@sha256:193b4d79...`
- **KBS image:** `registry.redhat.io/build-of-trustee/trustee-rhel9@sha256:85312d29...`
- **KBS version:** v0.1.0
- **Upstream project:** [confidential-containers/trustee](https://github.com/confidential-containers/trustee) / [trustee-operator](https://github.com/confidential-containers/trustee-operator)

## Summary

When `kbsAttestationPolicyConfigMapName` is set on the KbsConfig CR to
reference a user-created ConfigMap containing a custom OPA attestation policy,
the operator's v1.2 migration logic deletes the ConfigMap, creates a backup
suffixed `.v1.1`, and then fails to recreate it. This causes the KBS
deployment to fail with `ConfigMap not found`, and the operator enters a broken
reconcile loop.

Custom attestation policies cannot be used with `AllInOneDeployment`.

## Impact

Users cannot customize the OPA attestation policy to:

- Enforce specific TDX measurements (`mr_td`, `rtmr_1`, `rtmr_2`)
- Require minimum TCB dates or specific TCB statuses
- Block or allow specific Intel Advisory IDs
- Restrict attestation to specific platform configurations

The default policy accepts any valid DCAP quote regardless of measurements
(since RVPS is also broken — see `docs/rfe-trustee-rvps-local-json.md`). This
means there is no way to enforce measurement-based attestation in AllInOne mode.

## Current Behavior

1. User creates a ConfigMap with a custom `.rego` policy
2. User sets `kbsAttestationPolicyConfigMapName: custom-policy` on KbsConfig CR
3. Operator's reconcile loop runs the v1.2 migration logic
4. Migration **deletes** the user-created ConfigMap
5. Creates a backup as `custom-policy.v1.1`
6. Attempts to recreate the ConfigMap with operator-generated content — **fails**
7. KBS Deployment references the now-missing ConfigMap
8. Deployment fails: `ConfigMap "custom-policy" not found`
9. On each subsequent reconcile, the operator is stuck in the same loop

## Expected Behavior

When `kbsAttestationPolicyConfigMapName` is set:

1. The operator should mount the user-provided ConfigMap into the KBS pod at
   the attestation policy path
2. The user's `.rego` file should be used instead of the built-in default
3. The operator should NOT delete or modify the user's ConfigMap
4. If migration is needed, it should be a one-time operation that preserves
   user content

## Default Policy

The built-in `default_cpu.rego` policy checks (for TDX):

```rego
# Executables verification
executables_verified if {
    query_reference_value("rtmr_1") == null
    # ... or matches expected values
}

# Hardware verification
hardware_verified if {
    input.tee == "tdx"
    input.tcb_status == "UpToDate"
    !input.is_debuggable
    # ... collateral not expired
}

# Configuration verification
config_verified if {
    query_reference_value("xfam") == null
    # ... or matches expected values
}
```

All `query_reference_value()` calls return null due to the RVPS bug, so
executables and configuration checks always pass via the null-fallback path.

## Workaround

None exists for AllInOneDeployment. The operator reconcile loop:

- Prevents direct ConfigMap edits (reverts within seconds)
- Deletes ConfigMaps referenced via `kbsAttestationPolicyConfigMapName`
- Does not expose an admin API for policy updates

## Where to Fix

The operator's v1.2 migration logic should not unconditionally delete
user-provided ConfigMaps. The migration should:

1. Check if the ConfigMap is user-managed vs operator-managed
2. Skip migration for user-provided policy ConfigMaps
3. Mount the user's ConfigMap as-is when the field is set

## Related Issues

- `docs/rfe-trustee-rvps-local-json.md` — RVPS reference values not loaded
  (compounds this issue: even the default policy can't check measurements)
- `docs/rfe-trustee-kbs-dirpath-migration.md` — Same v1.2 migration logic
  causes `dir_path` bug

## Environment

- OpenShift 4.22.6, bare metal, Intel TDX, FIPS enabled
- KataConfig with `kata-cc` runtime class, TDX confidential VMs
- Full attestation flow working (DCAP passes), but custom policies blocked
