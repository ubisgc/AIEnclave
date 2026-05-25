# AIEnclave workspace image — R3+
#
# UBI9-minimal base for OpenShift R6 portability (ADR 0008 TBD).
# Installs gh CLI + gh-copilot extension. Intentionally omits cluster tools
# (kubectl, oc, helm, ssh, scp) — enforcement layer 1 (don't install the binary).
# PATH wrappers (layer 3) arrive via ConfigMap volumeMount at runtime (ADR 0007).
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

ARG GH_VERSION=2.52.0

RUN microdnf install -y \
        bash \
        curl \
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

# gh copilot extension — installed at build time, no runtime auth needed for install.
# Pin this to a specific tag before R6 (currently unpinned: acceptable for Kind dev loop).
ENV HOME=/root
RUN gh extension install github/gh-copilot

WORKDIR /home/user
