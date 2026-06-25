#!/bin/bash

export PCCS_API_KEY=""

if [ -z "${PCCS_API_KEY}" ]; then
  echo "PCCS_API_KEY var cannot be empty"
  exit 1
fi

oc create namespace intel-dcap

oc project intel-dcap

oc create serviceaccount pccs-sa -n intel-dcap

oc create serviceaccount qgs-sa -n intel-dcap

oc adm policy add-scc-to-user privileged -z pccs-sa -n intel-dcap

oc adm policy add-scc-to-user privileged -z qgs-sa -n intel-dcap

oc project default

export PCCS_USER_TOKEN="${PCCS_USER_TOKEN:-mytoken}"

export PCCS_ADMIN_TOKEN="${PCCS_ADMIN_TOKEN:-mytoken}"

export PCCS_NODE=$(oc get nodes \
  -l 'node-role.kubernetes.io/control-plane=,node-role.kubernetes.io/master=' \
  -o jsonpath='{.items[0].metadata.name}')

export CLUSTER_HTTPS_PROXY="$(oc get proxy/cluster \
  -o jsonpath={.spec.httpsProxy})"

export CLUSTER_NO_PROXY="$(oc get proxy/cluster \
  -o jsonpath={.spec.noProxy})"

export PCCS_USER_TOKEN_HASH=$(echo -n "$PCCS_USER_TOKEN" | sha512sum | tr -d '[:space:]-')

export PCCS_ADMIN_TOKEN_HASH=$(echo -n "$PCCS_ADMIN_TOKEN" | sha512sum | tr -d '[:space:]-')

export PCCS_PEM_CERT_PATH=$(mktemp -d)
export PCCS_PEM_CERT_PATH="/tmp/tmp.Ezw933GqUD/"

openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 \
  -keyout $PCCS_PEM_CERT_PATH/private.pem \
  -out $PCCS_PEM_CERT_PATH/certificate.pem \
  -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=www.example.com"

export PCCS_PEM=$(cat "$PCCS_PEM_CERT_PATH"/private.pem | base64 | tr -d '\n')

export PCCS_CERT=$(cat "$PCCS_PEM_CERT_PATH"/certificate.pem | base64 | tr -d '\n')

oc create secret generic pccs-secrets \
    --namespace intel-dcap \
    --from-literal=PCCS_API_KEY="$PCCS_API_KEY" \
    --from-literal=PCCS_USER_TOKEN_HASH="$PCCS_USER_TOKEN_HASH" \
    --from-literal=USER_TOKEN="$PCCS_USER_TOKEN" \
    --from-literal=PCCS_ADMIN_TOKEN_HASH="$PCCS_ADMIN_TOKEN_HASH"

oc apply -f <(cat pccs.yaml.in|envsubst)

oc set serviceaccount deployment/pccs pccs-sa -n intel-dcap

oc apply -f qgs.yaml

oc set serviceaccount daemonset/tdx-qgs qgs-sa -n intel-dcap
