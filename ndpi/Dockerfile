# syntax=docker/dockerfile:1
#
# Builds the xt-ndpi-dkms .deb in a clean Ubuntu 24.04 (noble) image, matching
# the target hosts. Only source is staged into the package — the kernel module
# is compiled by DKMS on the target, not here — so this image needs no kernel
# headers. Driven by compose.yaml:  docker compose run --rm --build build
#
# Stages:
#   base    - ubuntu + a user mapped to the host UID/GID
#   builder - adds build tooling, builds the .deb (unprivileged)
#   export  - minimal final layer holding only the .deb, owned by that user

FROM ubuntu:24.04 AS base
ENV DEBIAN_FRONTEND=noninteractive

# Map an in-container user to the host UID/GID so artifacts are owned by the
# invoking user, not root. (debian/control sets Rules-Requires-Root: no, so the
# package build itself runs fine unprivileged.) The image ships 'ubuntu' as
# 1000:1000; an already taken UID or GID is shared via -o (non-unique).
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USER_NAME=builder
ARG GROUP_NAME=builder
RUN (test "${USER_ID}" != ""  || (echo "ARG USER_ID is empty"; exit 1)) \
    && (test "${GROUP_ID}" != ""  || (echo "ARG GROUP_ID is empty"; exit 1)) \
    && (test "${USER_NAME}" != ""  || (echo "ARG USER_NAME is empty"; exit 1)) \
    && (test "${GROUP_NAME}" != ""  || (echo "ARG GROUP_NAME is empty"; exit 1)) \
    && GROUP_FLAG="$(getent group "${GROUP_ID}" >/dev/null && printf -- -o || true)" \
    && USER_FLAG="$(getent passwd "${USER_ID}" >/dev/null && printf -- -o || true)" \
    && groupadd -g "${GROUP_ID}" $GROUP_FLAG "${GROUP_NAME}" \
    && useradd -m -u "${USER_ID}" $USER_FLAG -g "${GROUP_NAME}" "${USER_NAME}" \
    && mkdir -p /build /artifacts \
    && chown -R ${USER_NAME}:${GROUP_NAME} /build /artifacts

FROM base AS builder
# Build-time tooling only: debhelper + dh-dkms to build the package, autotools
# to run autogen.sh (so the shipped tree carries ./configure). No libpcap or
# kernel headers — the module is built on the target by DKMS, not here.
RUN --mount=type=cache,target=/var/lib/apt/lists/,sharing=private \
    apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git \
        build-essential debhelper dh-dkms dpkg-dev fakeroot rsync \
         autoconf automake libtool pkg-config gettext \
        libxtables-dev

ARG NDPI_REPO=https://github.com/vel21ripn/nDPI.git
# Empty by default -> falls back to the pinned ./NDPI_REF file.
ARG NDPI_REF=""
ARG USER_NAME=builder
USER ${USER_NAME}
WORKDIR /build

# Pinned revision (overridable via the NDPI_REF build arg / compose env).
COPY --chown=${USER_NAME} NDPI_REF /build/NDPI_REF
RUN REF="${NDPI_REF:-$(cat /build/NDPI_REF)}" \
    && echo "── nDPI: $NDPI_REPO @ $REF ──" \
    && git clone "$NDPI_REPO" src \
    && git -C src checkout --quiet "$REF" \
    && git -C src --no-pager log -1 --oneline

# Generate ./configure so on-target DKMS builds need no autotools.
RUN cd src && ./autogen.sh >/dev/null 2>&1; test -x configure

# Overlay our packaging and build a binary-only, unsigned .deb (unprivileged).
COPY --chown=${USER_NAME} debian/ /build/src/debian/
RUN cd src && chmod +x debian/rules && dpkg-buildpackage -us -uc -b \
    && cp /build/xt-ndpi-*_*.deb /artifacts/

# Minimal final layer: just the .deb in /artifacts, owned by the host-mapped
# user. /artifacts is baked into the image; the host folder is bind-mounted at
# a separate path (/export) so it never shadows this.
FROM base AS export
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USER_NAME=builder
RUN mkdir -p /artifacts /export && chown ${USER_ID}:${GROUP_ID} /artifacts /export
COPY --from=builder --chown=${USER_ID}:${GROUP_ID} /artifacts/ /artifacts/
USER ${USER_NAME}
WORKDIR /artifacts
