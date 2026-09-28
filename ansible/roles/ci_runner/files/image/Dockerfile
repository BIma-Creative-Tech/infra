# syntax=docker/dockerfile:1
# Runner GitHub Actions ephemeral untuk sysbox-runc (plan 12 R3/R6, ADR 0014). Dibangun oleh role ci_runner.
# Basis: image resmi actions/runner (MIT), di-pin DIGEST (index multi-arch) — menggantikan verifikasi checksum tarball.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG GH_VERSION
ARG GH_SHA256
ARG CI_RUNNER_IMAGE_VERSION

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# iptables: jaringan dockerd DALAM (bridge/NAT inner container). xz-utils/zip: tarball Flutter, artefak.
# Paket dari arsip Ubuntu noble (apt, bukan pin versi: image dibangun ulang tiap bump runner ≤ 21 hari, Trivy menilai).
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends iptables xz-utils zip unzip openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI (MIT) — rilis resmi cli/cli, sha256 di-pin.
RUN curl -fsSL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
 && echo "${GH_SHA256}  /tmp/gh.tgz" | sha256sum -c - \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_amd64"

# Tanpa sudo untuk job (NNP di container juga mematikannya): cabut grup sudo + sudoers runner.
RUN gpasswd -d runner sudo \
 && rm -f /etc/sudoers.d/runner \
 && mkdir -p /etc/docker /opt/ci-runner/hooks

COPY daemon.json /etc/docker/daemon.json
COPY entrypoint.sh /opt/ci-runner/entrypoint.sh
COPY hooks/ /opt/ci-runner/hooks/
COPY android-bootstrap.sh /opt/ci-runner/android-bootstrap.sh
RUN chmod 0755 /opt/ci-runner/entrypoint.sh /opt/ci-runner/android-bootstrap.sh /opt/ci-runner/hooks/*.sh

# Cache persisten (bind /srv/ci/cache → /cache). Pengganti actions/cache + setup-* cache di self-hosted.
ENV RUNNER_TOOL_CACHE=/cache/toolcache \
    AGENT_TOOLSDIRECTORY=/cache/toolcache \
    npm_config_cache=/cache/npm \
    PUB_CACHE=/cache/pub \
    GRADLE_USER_HOME=/cache/gradle \
    ANDROID_HOME=/cache/android-sdk \
    ANDROID_SDK_ROOT=/cache/android-sdk \
    FLUTTER_TARBALL_CACHE=/cache/flutter \
    TRIVY_CACHE_DIR=/cache/trivy \
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ci-runner/hooks/job-started.sh \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/ci-runner/hooks/job-completed.sh \
    CI_RUNNER_IMAGE_VERSION=${CI_RUNNER_IMAGE_VERSION}

# Entrypoint jalan sebagai root-container (dipetakan sysbox ke uid host tak berhak) untuk dockerd dalam, lalu
# turun ke uid 1001 (setpriv) untuk run.sh. JIT config dibaca dari STDIN (tidak di argv/env/inspect host).
USER root
WORKDIR /home/runner
ENTRYPOINT ["/opt/ci-runner/entrypoint.sh"]
