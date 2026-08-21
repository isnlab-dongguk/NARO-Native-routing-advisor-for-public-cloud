# syntax=docker/dockerfile:1

# Experiment 2 measurement tool image.
#
# Every tool the measurement needs is preinstalled on ubuntu:22.04. Pods never
# run APT at startup, so they become Ready immediately and no iteration
# re-downloads 26 packages (~9.5MB) from archive.ubuntu.com (measured at over
# 6 minutes). Pinning the tool versions at image build time also makes
# iterations more reproducible.
#
# Only iperf3 is replaced by a source build. The Jammy APT iperf3 is frozen at
# 3.9-1+deb11u1ubuntu0.1 and has two limits: (1) -P/--parallel adds sockets but
# not threads, so sending is bound to a single core (multithreading landed in
# 3.16); (2) there is no UDP GSO, so it calls sendmsg() once per datagram
# (GSO/GRO landed in 3.21). That is why the experiment 2 UDP measurement was
# capped by the iperf3 syscall rate rather than by the network. Every other tool
# (netperf, sysstat, ...) uses the stock Jammy version.

ARG BASE_IMAGE=ubuntu:22.04
ARG IPERF_VERSION=3.21

FROM ${BASE_IMAGE} AS builder
ARG IPERF_VERSION
# Reproducibility pin: the SHA-256 of iperf-3.21.tar.gz as downloaded from
# downloads.es.net, so every iteration builds the same source. It is an
# integrity pin, not a third-party signature check.
ARG IPERF_SHA256=656e4405ebd620121de7ceca3eaf43a88f79ea1b857d041a6a0b1314801acdd8

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN curl -fsSL -o iperf.tar.gz \
      "https://downloads.es.net/pub/iperf/iperf-${IPERF_VERSION}.tar.gz" \
 && printf '%s  iperf.tar.gz\n' "${IPERF_SHA256}" | sha256sum -c - \
 && tar xzf iperf.tar.gz

WORKDIR /build/iperf-${IPERF_VERSION}
# --disable-shared: no libiperf.so is produced, so the runtime layer only needs
# the single executable and no ldconfig.
RUN ./configure --prefix=/usr/local --disable-shared \
 && make -j"$(nproc)" \
 && make install \
 && strip /usr/local/bin/iperf3

FROM ${BASE_IMAGE}
ARG IPERF_VERSION

# Must stay identical to TOOL_PACKAGES in exp2_benchmark.sh. A mismatch fails
# immediately in the dpkg-query check of the pod startup command.
ARG TOOL_PACKAGES="ca-certificates netcat-openbsd netperf python3 socat sysstat"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends ${TOOL_PACKAGES} \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/iperf3 /usr/local/bin/iperf3

# PATH puts /usr/local/bin ahead of /usr/bin, so the source-built binary wins.
# The APT iperf3 is never installed.
RUN /usr/local/bin/iperf3 --version \
 && test "$(command -v iperf3)" = /usr/local/bin/iperf3 \
 && for tool in netperf netserver mpstat nc python3 socat; do command -v "$tool" >/dev/null; done \
 && dpkg-query -W ${TOOL_PACKAGES} >/dev/null \
 && printf '%s\n' "${IPERF_VERSION}" >/etc/exp2-iperf3-version \
 && printf '%s\n' "${TOOL_PACKAGES}" >/etc/exp2-tool-packages

LABEL org.opencontainers.image.title="exp2-tools" \
      org.opencontainers.image.description="ubuntu:22.04 + iperf3 built from source + the experiment 2 measurement tools" \
      exp2.iperf3.version="${IPERF_VERSION}" \
      exp2.iperf3.source="https://downloads.es.net/pub/iperf/" \
      exp2.tool.packages="${TOOL_PACKAGES}"
