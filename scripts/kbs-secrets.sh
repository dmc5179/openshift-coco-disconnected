#!/bin/bash
set -euo pipefail

# Manage KBS repository secrets for CoCo workloads.
#
# KBS stores secrets at paths like: default/<repository>/<key>
# Workloads fetch them via: kbs:///default/<repository>/<key>
#
# Secrets are stored in the KBS pod's local filesystem and referenced
# via the KbsConfig CR's kbsSecretResources field.

KBS_NAMESPACE="${KBS_NAMESPACE:-trustee-operator-system}"
KBS_DEPLOYMENT="${KBS_DEPLOYMENT:-trustee-deployment}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Manage KBS repository secrets for CoCo workloads.

Commands:
  set <repository> <key> <value>     Store a secret value
  set-file <repository> <key> <path> Store a secret from a file
  get <repository> <key>             Retrieve a secret value
  list                               List all stored secrets
  delete <repository> <key>          Delete a secret
  register <repository> <key>        Add a secret to KbsConfig CR's kbsSecretResources

Options:
  -n, --namespace NS     KBS namespace (default: trustee-operator-system)
  -h, --help             Show this help

How secrets work in CoCo:
  1. Secrets are stored in KBS at: default/<repository>/<key>
  2. The KbsConfig CR must list secrets in kbsSecretResources for the
     operator to mount the corresponding Kubernetes Secrets
  3. Workloads fetch secrets via the CDH at:
     kbs:///default/<repository>/<key>

Example workflow:
  # Create a Kubernetes Secret
  oc create secret generic my-app-secrets -n $KBS_NAMESPACE \\
    --from-literal=db-password=s3cret \\
    --from-literal=api-key=abc123

  # Store values in KBS
  $(basename "$0") set my-app db-password s3cret
  $(basename "$0") set my-app api-key abc123

  # Register with KbsConfig so operator mounts the Secret
  $(basename "$0") register my-app db-password

  # In the CoCo pod, CDH fetches via:
  #   kbs:///default/my-app/db-password
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) KBS_NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage ;;
        set|set-file|get|list|delete|register) break ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ $# -eq 0 ]]; then
    usage
fi

COMMAND="$1"
shift

kbs_pod() {
    oc get pods -n "$KBS_NAMESPACE" -l app=kbs \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

case "$COMMAND" in
    set)
        if [[ $# -lt 3 ]]; then
            echo "Usage: $(basename "$0") set <repository> <key> <value>"
            exit 1
        fi
        REPO="$1"; KEY="$2"; VALUE="$3"
        RESOURCE_PATH="default/${REPO}/${KEY}"
        echo "Storing secret at: $RESOURCE_PATH"

        POD=$(kbs_pod)
        if [[ -z "$POD" ]]; then
            echo "ERROR: KBS pod not found in namespace $KBS_NAMESPACE"
            exit 1
        fi

        oc exec -n "$KBS_NAMESPACE" "$POD" -c kbs -- \
            curl -s -X POST "http://localhost:8080/kbs/v0/resource/${RESOURCE_PATH}" \
            -H 'Content-Type: application/octet-stream' \
            -d "$VALUE"
        echo ""
        echo "Secret stored successfully."
        ;;

    set-file)
        if [[ $# -lt 3 ]]; then
            echo "Usage: $(basename "$0") set-file <repository> <key> <path>"
            exit 1
        fi
        REPO="$1"; KEY="$2"; FILE_PATH="$3"
        RESOURCE_PATH="default/${REPO}/${KEY}"

        if [[ ! -f "$FILE_PATH" ]]; then
            echo "ERROR: File not found: $FILE_PATH"
            exit 1
        fi

        echo "Storing secret from file at: $RESOURCE_PATH"

        POD=$(kbs_pod)
        if [[ -z "$POD" ]]; then
            echo "ERROR: KBS pod not found in namespace $KBS_NAMESPACE"
            exit 1
        fi

        VALUE=$(cat "$FILE_PATH")
        oc exec -n "$KBS_NAMESPACE" "$POD" -c kbs -- \
            curl -s -X POST "http://localhost:8080/kbs/v0/resource/${RESOURCE_PATH}" \
            -H 'Content-Type: application/octet-stream' \
            -d "$VALUE"
        echo ""
        echo "Secret stored successfully."
        ;;

    get)
        if [[ $# -lt 2 ]]; then
            echo "Usage: $(basename "$0") get <repository> <key>"
            exit 1
        fi
        REPO="$1"; KEY="$2"
        RESOURCE_PATH="default/${REPO}/${KEY}"

        POD=$(kbs_pod)
        if [[ -z "$POD" ]]; then
            echo "ERROR: KBS pod not found in namespace $KBS_NAMESPACE"
            exit 1
        fi

        STORAGE_PATH="/opt/confidential-containers/storage/repository/default\\x2F${REPO}\\x2F${KEY}"
        RESULT=$(oc exec -n "$KBS_NAMESPACE" "$POD" -c kbs -- cat "$STORAGE_PATH" 2>/dev/null || echo "")
        if [[ -z "$RESULT" ]]; then
            echo "Secret not found: $RESOURCE_PATH"
            exit 1
        fi
        echo "$RESULT"
        ;;

    list)
        POD=$(kbs_pod)
        if [[ -z "$POD" ]]; then
            echo "ERROR: KBS pod not found in namespace $KBS_NAMESPACE"
            exit 1
        fi

        echo "KBS repository secrets:"
        echo ""
        oc exec -n "$KBS_NAMESPACE" "$POD" -c kbs -- \
            find /opt/confidential-containers/storage/repository -type f 2>/dev/null | \
            sed 's|/opt/confidential-containers/storage/repository/||' | \
            sed 's|\\x2F|/|g' | \
            sort
        ;;

    delete)
        if [[ $# -lt 2 ]]; then
            echo "Usage: $(basename "$0") delete <repository> <key>"
            exit 1
        fi
        REPO="$1"; KEY="$2"
        RESOURCE_PATH="default/${REPO}/${KEY}"

        POD=$(kbs_pod)
        if [[ -z "$POD" ]]; then
            echo "ERROR: KBS pod not found in namespace $KBS_NAMESPACE"
            exit 1
        fi

        STORAGE_PATH="/opt/confidential-containers/storage/repository/default\\x2F${REPO}\\x2F${KEY}"
        oc exec -n "$KBS_NAMESPACE" "$POD" -c kbs -- rm -f "$STORAGE_PATH" 2>/dev/null
        echo "Deleted: $RESOURCE_PATH"
        ;;

    register)
        if [[ $# -lt 2 ]]; then
            echo "Usage: $(basename "$0") register <repository> <key>"
            echo ""
            echo "This adds a Kubernetes Secret reference to the KbsConfig CR's"
            echo "kbsSecretResources list. The Secret must exist in the $KBS_NAMESPACE"
            echo "namespace with the same name as <repository>."
            exit 1
        fi
        REPO="$1"; KEY="$2"

        echo "Checking KbsConfig CR..."
        EXISTING=$(oc get kbsconfig kbsconfig -n "$KBS_NAMESPACE" \
            -o jsonpath='{.spec.kbsSecretResources}' 2>/dev/null || echo "")

        if echo "$EXISTING" | grep -q "$REPO"; then
            echo "Secret '$REPO' is already in kbsSecretResources."
        else
            echo "Adding '$REPO' to kbsSecretResources..."
            oc patch kbsconfig kbsconfig -n "$KBS_NAMESPACE" --type=json \
                -p "[{\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$REPO\"}]"
            echo "Done. The operator will reconcile and mount the Secret."
        fi
        ;;

    *)
        echo "Unknown command: $COMMAND"
        usage
        ;;
esac
