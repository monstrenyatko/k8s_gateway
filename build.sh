#!/bin/bash

# Gather parameters
if [ $# -eq 0 ];then
    perro "No argument supplied"
    exit 1
fi
build_tag=$1
build_params=$2

# Verify provided parameters
echo TAG: "${build_tag:?}"
echo PARAMS: "${build_params}"

# Exit on error
set -e

COMMIT=$(git describe --dirty --always)
LDFLAGS="-s -w -X github.com/coredns/coredns/coremain.GitCommit=${COMMIT}"

docker buildx build --progress plain --platform linux/arm64,linux/amd64 --tag ${build_tag} --build-arg LDFLAGS="${LDFLAGS}" ${build_params} .
