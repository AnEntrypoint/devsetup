# Dev desktop: webtop XFCE + the apt packages the host has.
# Languages and caches are NOT baked in; launch.sh mounts them read-only from the host.
FROM lscr.io/linuxserver/webtop:ubuntu-xfce

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config \
      libssl-dev libffi-dev zlib1g-dev libsqlite3-dev \
      curl ca-certificates git unzip jq gnupg \
      nvidia-vaapi-driver vainfo tmux \
 && rm -rf /var/lib/apt/lists/*

# Shared tmux config (same file as the host's /etc/tmux.conf)
COPY tmux/tmux.conf /etc/tmux.conf

# GPU flags for Chromium: the launcher sources /etc/chromium.d/*, so the wrapper path gets them
COPY chromium-gpu.conf /etc/chromium.d/90-gpu

# Direct calls to the real binary (/usr/lib/chromium/chromium) skip the launcher.
# Move the binary aside and put a shim in its place that adds the same flags.
RUN mv /usr/lib/chromium/chromium /usr/lib/chromium/chromium.real \
 && printf '%s\n' '#!/bin/sh' '. /etc/chromium.d/90-gpu' 'exec /usr/lib/chromium/chromium.real "$@" $CHROMIUM_GPU_FLAGS' > /usr/lib/chromium/chromium \
 && chmod 755 /usr/lib/chromium/chromium

# gh and gcloud from the same official repos as the host (no credentials are copied in)
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh google-cloud-cli \
 && rm -rf /var/lib/apt/lists/*
