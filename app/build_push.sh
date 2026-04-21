#!/usr/bin/env bash

# docker buildx create --use

PLATFORMS="linux/amd64,linux/arm64"
DOCKERNAME="docker.io/davidaparicio/streamlit-keycloak"
REDHATNAME="quay.io/davidaparicio/streamlit-keycloak"
IMAGEVERSION="0.6.0"

# Build and push to both registries simultaneously
# Multi-platform builds with --push create manifests directly in the registry,
# so we use multiple -t flags to push to both Docker Hub and Quay.io at once
docker buildx build \
  --platform=${PLATFORMS} \
  -t ${REDHATNAME}:${IMAGEVERSION} \
  --push .
# docker tag ${DOCKERNAME}:${IMAGEVERSION} ${REDHATNAME}:${IMAGEVERSION}