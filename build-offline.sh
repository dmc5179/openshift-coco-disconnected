#!/bin/bash

# Build pcr collection container image
podman build --squash -t quay.io/danclark/pcr-collector:latest -f Containerfile-pcr-collector .

podman push --authfile=/home/danclark/quay-pull-secret.json quay.io/danclark/pcr-collector:latest
