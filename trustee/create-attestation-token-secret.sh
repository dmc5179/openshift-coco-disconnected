#!/bin/bash

openssl ecparam -name prime256v1 -genkey -noout -out token.key

openssl req -new -x509 -key token.key -out token.crt -days 365 \
  -subj "/CN=<custom_cn>/O=<custom_org>"

oc create secret generic attestation-token \
  --from-file=token.crt \
  --from-file=token.key \
  -n trustee-operator-system


