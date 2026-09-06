# RFE: Trustee Operator v1.2 Migration Sets Wrong KBS Storage dir_path

## Component

- **Operator:** Red Hat build of Trustee (trustee-operator)
- **Version:** v1.2.1 (`trustee-operator.v1.2.1`)
- **Operator image:** `registry.redhat.io/build-of-trustee/trustee-rhel9-operator@sha256:193b4d79...`
- **KBS image:** `registry.redhat.io/build-of-trustee/trustee-rhel9@sha256:85312d29...`
- **KBS version:** v0.1.0
- **Upstream project:** [confidential-containers/trustee](https://github.com/confidential-containers/trustee) / [trustee-operator](https://github.com/confidential-containers/trustee-operator)

## Summary

When the Trustee operator is upgraded from v1.1 to v1.2, the operator's
reconcile loop regenerates the KBS TOML configuration but sets an incorrect
`dir_path` for the `resource` plugin (LocalFs storage). The KBS pod
CrashLoopBackOff because it cannot find or create its repository directory at
the wrong path.

Deleting and recreating the KbsConfig CR causes the operator to generate a
fresh v1.2 TOML with the correct `dir_path`, resolving the issue.

## Impact

After an operator upgrade from v1.1 to v1.2, KBS enters CrashLoopBackOff and
attestation is completely broken until the KbsConfig CR is manually deleted and
recreated. This is a disruptive operation that:

- Causes attestation downtime during the upgrade window
- Requires manual intervention (not handled by OLM or the operator itself)
- Loses any custom KbsConfig CR fields that aren't captured in version control
  (though AutoShift-managed deployments can simply re-apply the policy)

## Current Behavior

1. Operator v1.1 is installed with a working KbsConfig CR
2. OLM upgrades the operator to v1.2
3. The operator's reconcile loop regenerates the KBS TOML config (stored in
   the `kbs-config-cm` ConfigMap)
4. The generated TOML contains an incorrect `dir_path` in the `[[plugins]]`
   section — the path does not match the volume mount in the KBS pod spec
5. KBS fails to start because the storage directory is missing or inaccessible
6. Pod enters CrashLoopBackOff

## Expected Behavior

The operator should either:

1. **Migrate the `dir_path` correctly** during the v1.1 → v1.2 upgrade,
   updating both the TOML config and volume mounts to match, or
2. **Preserve the existing `dir_path`** if the storage path hasn't changed
   between versions, or
3. **Use a fixed, well-known path** that is consistent across versions
   (e.g., `/opt/confidential-containers/kbs/repository`)

The correct v1.2 path (generated on fresh install) is:

```toml
[[plugins]]
name = "resource"
type = "LocalFs"
dir_path = "/opt/confidential-containers/kbs/repository"
```

## Workaround

Delete and recreate the KbsConfig CR to force the operator to generate a fresh
v1.2 configuration:

```bash
# Save the current KbsConfig spec
oc get kbsconfig kbsconfig -n trustee-operator-system -o yaml > /tmp/kbsconfig-backup.yaml

# Delete the CR
oc delete kbsconfig kbsconfig -n trustee-operator-system

# Wait for cleanup
sleep 10

# Recreate (the operator generates correct v1.2 TOML)
oc apply -f /tmp/kbsconfig-backup.yaml

# Verify KBS pod starts
oc get pods -n trustee-operator-system -l app=kbs -w
```

For AutoShift-managed deployments, the ACM policy will recreate the KbsConfig
CR automatically once deleted. No manual re-apply is needed.

## Where to Fix

The operator's reconcile logic that generates the KBS TOML should handle the
migration path explicitly. When detecting a v1.1 → v1.2 upgrade (e.g., by
checking the existing ConfigMap's TOML schema version or the presence of
v1.1-specific fields), it should regenerate the full TOML from scratch rather
than partially updating it.

Alternatively, the `dir_path` should be derived from the KbsConfig CR spec
(or a well-known constant) rather than carried forward from the existing
ConfigMap, ensuring it's always correct regardless of upgrade path.

## Environment

- OpenShift 4.22.6, bare metal, Intel TDX, FIPS enabled
- Upgraded from trustee-operator v1.1 to v1.2.1 via OLM
- KataConfig with `kata-cc` runtime class, TDX confidential VMs
