# AIEnclave workspace image — R4
#
# UBI9-minimal base for OpenShift R6 portability (ADR 0008 TBD).
# Installs gh CLI + gh-copilot. Intentionally omits cluster tools
# (kubectl, oc, helm) — enforcement layer 1 (don't install the binary).
# Note: git pulls in openssh-clients, so ssh/scp ARE present; deny wrappers
# at /denied-bins cover them (layer 3). PATH prepended in DevWorkspace spec.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

ARG GH_VERSION=2.52.0

RUN microdnf install -y \
        bash \
        git \
        tar \
        gzip \
        jq \
    && microdnf clean all

# gh CLI — direct release download, no package repo needed, version pinned.
RUN curl -fsSL \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local \
        "gh_${GH_VERSION}_linux_amd64/bin/gh" \
    && chmod +x /usr/local/bin/gh

# gh copilot extension — install to /opt/gh-data (outside /home/user) so the PVC mount at
# /home/user at runtime does not shadow the baked-in extension binary. gh 2.x reads
# XDG_DATA_HOME for the data dir (extensions live at {XDG_DATA_HOME}/gh/extensions/).
# Set the same XDG_DATA_HOME in the DevWorkspace spec so the runtime gh finds the extension.
# Pin to a specific release before R6 (currently unpinned: acceptable for Kind dev loop).
ENV HOME=/root XDG_DATA_HOME=/opt/gh-data
RUN curl -fsSL https://gh.io/copilot-install | bash && chmod -R a+rX /opt/gh-data

# World-writable home for the arbitrary UID DWO assigns at runtime (no /etc/passwd entry).
# Separate from extension data dir — PVC mounts here; extension stays in /opt/gh-data.
RUN mkdir -p /home/user && chmod 777 /home/user
ENV HOME=/home/user

# Deny wrappers baked in at /denied-bins (ADR 0007 layer 3).
# DWO blocks pod-overrides on spec.containers so ConfigMap mount is not viable;
# baking into the image is the only way to get files into the container.
RUN mkdir -p /denied-bins && \
    for tool in kubectl oc helm ssh scp; do \
        printf '#!/bin/sh\necho "%s: blocked by AIEnclave policy (ADR 0007)" >&2\nexit 1\n' \
            "$tool" > /denied-bins/$tool && \
        chmod +x /denied-bins/$tool; \
    done

WORKDIR /home/user
