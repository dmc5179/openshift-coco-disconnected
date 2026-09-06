#!/bin/bash
set -euo pipefail

KBS_URL="${KBS_URL:-http://kbs-service.trustee-operator-system.svc.cluster.local:8080}"
POLICY_MODE="${1:-debug}"
OUTPUT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [debug|secure] [--output FILE] [--kbs-url URL]

Generate cc_init_data for CoCo workloads. Output is gzipped+base64 TOML
suitable for the io.katacontainers.config.hypervisor.cc_init_data annotation.

Modes:
  debug   - All operations allowed (ExecProcess, ReadStream, WriteStream)
  secure  - Exec, ReadStream, WriteStream blocked (production)

Options:
  --kbs-url URL   KBS service URL (default: in-cluster service)
  --output FILE   Write to file instead of stdout

Example:
  # Generate and apply directly
  INITDATA=\$(./scripts/generate-initdata.sh debug)

  # Use in a pod annotation
  io.katacontainers.config.hypervisor.cc_init_data: "\$INITDATA"
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|secure)  POLICY_MODE="$1"; shift ;;
        --kbs-url)     KBS_URL="$2"; shift 2 ;;
        --output)      OUTPUT="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1"; usage ;;
    esac
done

if [[ "$POLICY_MODE" == "debug" ]]; then
    EXEC_POLICY="default ExecProcessRequest := true"
    READ_POLICY="default ReadStreamRequest := true"
    WRITE_POLICY="default WriteStreamRequest := true"
else
    EXEC_POLICY="default ExecProcessRequest := false"
    READ_POLICY="default ReadStreamRequest := false"
    WRITE_POLICY="default WriteStreamRequest := false"
fi

TOML=$(cat <<TOML_EOF
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]
url = "${KBS_URL}"

[token_configs.kbs]
url = "${KBS_URL}"
'''

"cdh.toml"  = '''
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "${KBS_URL}"
'''

"policy.rego" = '''
package agent_policy

default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
${EXEC_POLICY}
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
${READ_POLICY}
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SetPolicyRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
${WRITE_POLICY}
'''
TOML_EOF
)

ENCODED=$(echo "$TOML" | gzip | base64 -w0)

if [[ -n "$OUTPUT" ]]; then
    echo "$ENCODED" > "$OUTPUT"
    echo "Wrote initdata to $OUTPUT (${#ENCODED} chars, mode=$POLICY_MODE)" >&2
else
    echo "$ENCODED"
fi
