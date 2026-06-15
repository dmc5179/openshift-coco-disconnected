#!/bin/bash

echo "Get Domain"
DOMAIN=$(oc get ingress.config/cluster -o jsonpath='{.spec.domain}')

echo "Get Route"
ROUTE="kbs-route-trustee-operator-system.${DOMAIN}"

echo "Generate crt and key"
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=kbs-trustee-operator-system/O=Red Hat" \
  -addext "subjectAltName=DNS:${ROUTE}"

echo "Load cert and key"
oc create secret tls trustee-tls-cert -n trustee-operator-system \
  --cert=tls.crt \
  --key=tls.key

echo "Generate and load token"
openssl ecparam -name prime256v1 -genkey -noout -out token.key
openssl req -new -x509 -key token.key -out token.crt -days 365   -subj "/CN=kbs-trustee-operator-system/O=Red Hat"
oc create secret tls trustee-token-cert -n trustee-operator-system   --cert=token.crt   --key=token.key

echo "deploy TrusteeConfig"
# Below is restrictive mode which just means we had to do the SSL part above first
cat <<EOF | oc apply -f -
apiVersion: confidentialcontainers.org/v1alpha1
kind: TrusteeConfig
metadata:
  name: trustee-config
  namespace: trustee-operator-system
spec:
  profileType: Restricted
  kbsServiceType: ClusterIP
  httpsSpec:
    tlsSecretName: trustee-tls-cert
  attestationTokenVerificationSpec:
    tlsSecretName: trustee-token-cert
EOF
