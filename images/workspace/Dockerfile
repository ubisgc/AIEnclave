# AIEnclave workspace image — R5
#
# UBI9-minimal base for OpenShift R6 portability (ADR 0008 TBD).
# Installs gh CLI + gh-copilot. Intentionally omits cluster tools
# (kubectl, oc, helm) — enforcement layer 1 (don't install the binary).
# Note: git pulls in openssh-clients, so ssh/scp ARE present; deny wrappers
# at /denied-bins cover them (layer 3). PATH prepended in DevWorkspace spec.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

ARG GH_VERSION=2.52.0
ARG NODE_VERSION=20.19.2

RUN microdnf install -y \
        bash \
        git \
        tar \
        gzip \
        jq \
    && microdnf clean all

# Node.js — direct binary download, version pinned. Provides node/npm/npx for AI CLI tooling.
# Installed to /usr/local so it is outside /home/user and unaffected by the PVC mount.
RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local \
        "node-v${NODE_VERSION}-linux-x64/bin/node" \
        "node-v${NODE_VERSION}-linux-x64/bin/npm" \
        "node-v${NODE_VERSION}-linux-x64/bin/npx" \
        "node-v${NODE_VERSION}-linux-x64/lib" \
        "node-v${NODE_VERSION}-linux-x64/include"

# gh CLI — direct release download, no package repo needed, version pinned.
RUN curl -fsSL \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local \
        "gh_${GH_VERSION}_linux_amd64/bin/gh" \
    && chmod +x /usr/local/bin/gh

# Standalone copilot CLI — installs binary to /usr/local/bin/copilot (not a gh extension).
# No home-dir dependency at install time; token written to ~/.copilot/ at runtime (on PVC).
# Pin to a specific release before R6 (currently unpinned: acceptable for Kind dev loop).
RUN curl -fsSL https://gh.io/copilot-install | bash

# Skills installed to /opt/skills (outside /home/user) so PVC mount does not shadow them.
# npm prefix set to /opt/skills so global installs land there, not in HOME.
# Build-time install avoids runtime npm registry egress requirement.
RUN npm install --global --prefix /opt/skills skills@latest \
    && chmod -R a+rX /opt/skills

# World-writable home for the arbitrary UID DWO assigns at runtime (no /etc/passwd entry).
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
