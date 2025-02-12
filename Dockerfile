# syntax=docker/dockerfile:1
# ARG must be first?
# BASE_DISTRIBUTION is used to switch between the old base distribution and distroless base images
ARG BASE_DISTRIBUTION=debug

# Version is the base image version from the TLD Makefile
ARG BASE_VERSION=latest
ARG ISTIO_BASE_REGISTRY=gcr.io/istio-release
ARG PROXY_VERSION=1.23.4


FROM ubuntu:22.04 AS builder

RUN apt update

RUN DEBIAN_FRONTEND=noninteractive apt-get -q -y install \
  autoconf \
  curl \
  libtool \
  patch \
  python3-pip \
  unzip \
  virtualenv \
  git \
  wget \
  clang \
  llvm \
  lld \
  libc++-dev \
  libc++abi-dev \
  libssl-dev

# Install bazelisk
RUN wget -O /usr/local/bin/bazel https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-$([ $(uname -m) = "aarch64" ] && echo "arm64" || echo "amd64")
RUN chmod +x /usr/local/bin/bazel

WORKDIR /stc

# COPY . .
RUN --mount=type=bind,target=. --mount=type=cache,target=/root/.cache bazel version

RUN --mount=type=bind,target=. --mount=type=cache,target=/root/.cache bazel fetch //:envoy

# It's killing my machine if run unlimited
# RUN --mount=type=cache,target=/root/.cache bazel build -c opt --local_ram_resources=HOST_RAM*.5 --local_cpu_resources=HOST_CPUS-2 //:envoy
RUN --mount=type=bind,target=. --mount=type=cache,target=/root/.cache bazel build -c opt --local_ram_resources=HOST_RAM*.5 --local_cpu_resources=HOST_CPUS-2 //:envoy

RUN --mount=type=bind,target=. --mount=type=cache,target=/root/.cache ls -la `bazel info -c opt bazel-bin`/
# We are mounting . to improve build time.
RUN --mount=type=bind,target=. --mount=type=cache,target=/root/.cache cp `bazel info -c opt bazel-bin`/envoy /

# Extra stripping
RUN strip /envoy

# Inspired by https://github.com/istio/istio/blob/master/pilot/docker/Dockerfile.proxyv2

# The following section is used as base image if BASE_DISTRIBUTION=debug
FROM ${ISTIO_BASE_REGISTRY}/base:${BASE_VERSION} AS debug

# The following section is used as base image if BASE_DISTRIBUTION=distroless
FROM ${ISTIO_BASE_REGISTRY}/iptables:${BASE_VERSION} AS distroless

# RUN echo ${ISTIO_BASE_REGISTRY}/iptablse:${BASE_VERSION}

# Copy files from the original docker image
# Original image to hijack
FROM ${ISTIO_BASE_REGISTRY}/proxyv2:${PROXY_VERSION} AS proxyv2



# This will build the final image based on either debug or distroless from above
# hadolint ignore=DL3006
FROM ${BASE_DISTRIBUTION:-debug}

WORKDIR /

# Copy Envoy bootstrap templates used by pilot-agent
COPY --from=proxyv2 /var/lib/istio/envoy/envoy_bootstrap_tmpl.json /var/lib/istio/envoy/envoy_bootstrap_tmpl.json
COPY --from=proxyv2  /var/lib/istio/envoy/gcp_envoy_bootstrap_tmpl.json /var/lib/istio/envoy/gcp_envoy_bootstrap_tmpl.json

ARG TARGETARCH
COPY --from=proxyv2 /usr/local/bin/pilot-agent /usr/local/bin/pilot-agent

# Install our Envoy.
COPY --from=builder /envoy /usr/local/bin/envoy

# Environment variable indicating the exact proxy sha - for debugging or version-specific configs
# ENV ISTIO_META_ISTIO_PROXY_SHA=$(eval sha256sum /usr/local/bin/envoy | cut -f1 -d " ")
# The pilot-agent will bootstrap Envoy.
ENTRYPOINT ["/usr/local/bin/pilot-agent"]
