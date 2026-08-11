# AvianVisitors: BirdNET-Pi plus the AvianVisitors collage overlay, as a single
# supervised container.
#
# arm64 only, by design. The BirdNET model runs through tflite_runtime, and
# scripts/install_helpers.sh resolves that wheel by (arch, python version) from
# a fixed set of GitHub release assets. Debian bookworm gives us python3.11,
# which pairs with tflite_runtime 2.17.1 for aarch64. Changing the base image
# release means changing the wheel, so the two are pinned together below.
#
# Build:  docker buildx build --platform linux/arm64 -f docker/Dockerfile -t avianvisitors .
# Run:    see docker-compose.yml at the repo root.

# ---------------------------------------------------------------------------
# Stage 1: build the Python virtualenv
# ---------------------------------------------------------------------------
# Split out so the ~800MB of build toolchain needed to compile the handful of
# packages without aarch64 wheels never reaches the runtime image.
FROM debian:bookworm-slim AS venv-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG TFLITE_WHL=tflite_runtime-2.17.1-cp311-cp311-linux_aarch64.whl
ARG TFLITE_BASE_URL=https://github.com/Nachtzuster/BirdNET-Pi/releases/download/v0.1/

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-dev python3-pip \
      build-essential pkg-config \
      libsndfile1-dev libffi-dev \
      curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Fetch the tflite wheel and swap it in for the "tensorflow" line, which is
# exactly what get_tf_whl() in scripts/install_helpers.sh does on bare metal.
# Done inline rather than by sourcing that function because it depends on
# uname -m and the live python, and cross-building would resolve them wrong.
COPY requirements.txt ./
RUN curl -fL -o "/build/${TFLITE_WHL}" "${TFLITE_BASE_URL}${TFLITE_WHL}" \
    && sed "s|tensorflow.*|/build/${TFLITE_WHL}|" requirements.txt > requirements_custom.txt \
    && cat requirements_custom.txt

RUN python3 -m venv /home/birdnet/BirdNET-Pi/birdnet \
    && /home/birdnet/BirdNET-Pi/birdnet/bin/pip install --no-cache-dir --upgrade pip wheel \
    && /home/birdnet/BirdNET-Pi/birdnet/bin/pip install --no-cache-dir -r requirements_custom.txt

# The venv records absolute paths, so it must be built at the same path it will
# be used at. Fail the build loudly here rather than at container start.
RUN /home/birdnet/BirdNET-Pi/birdnet/bin/python3 -c "import tflite_runtime.interpreter, librosa, streamlit, pandas; print('venv OK')"


# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG S6_OVERLAY_VERSION=3.2.0.2

LABEL org.opencontainers.image.title="AvianVisitors" \
      org.opencontainers.image.description="BirdNET-Pi with the AvianVisitors collage UI" \
      org.opencontainers.image.source="https://github.com/Twarner491/AvianVisitors" \
      org.opencontainers.image.licenses="CC-BY-NC-SA-4.0"

# icecast2 would otherwise open a debconf dialog and stall the build.
RUN echo "icecast2 icecast2/icecast-setup boolean false" | debconf-set-selections

# Caddy comes from the Cloudsmith repo, same source install_services.sh uses,
# because Debian does not package it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
       | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
       > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      caddy \
      php8.2-fpm php8.2-sqlite3 php8.2-curl php8.2-xml php8.2-zip php8.2-mbstring php8.2-cli \
      sqlite3 \
      icecast2 \
      sox libsox-fmt-mp3 alsa-utils ffmpeg \
      python3 python3-venv \
      git jq bc unzip wget \
      inotify-tools lsof net-tools procps usbutils \
      cron sudo xz-utils tzdata \
      libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# --- s6-overlay: the process supervisor that stands in for systemd -----------
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/s6-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-aarch64.tar.xz /tmp/s6-aarch64.tar.xz
RUN tar -C / -Jxpf /tmp/s6-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-aarch64.tar.xz \
    && rm -f /tmp/s6-noarch.tar.xz /tmp/s6-aarch64.tar.xz

# --- accounts ---------------------------------------------------------------
# Fixed uid/gid so a bind-mounted ./config keeps predictable ownership on the
# host. BIRDNET_USER is baked in as "birdnet": paths like
# /home/$BIRDNET_USER/BirdNET-Pi are hardcoded throughout the PHP and shell.
ARG BIRDNET_UID=1000
ARG BIRDNET_GID=1000
RUN groupadd -g ${BIRDNET_GID} birdnet \
    && useradd -m -u ${BIRDNET_UID} -g birdnet -s /bin/bash birdnet \
    && usermod -aG audio birdnet \
    && usermod -aG audio caddy \
    && usermod -aG birdnet caddy

# --- application ------------------------------------------------------------
COPY --chown=birdnet:birdnet . /home/birdnet/BirdNET-Pi
COPY --from=venv-builder --chown=birdnet:birdnet /home/birdnet/BirdNET-Pi/birdnet /home/birdnet/BirdNET-Pi/birdnet

WORKDIR /home/birdnet/BirdNET-Pi

# phpsysinfo is a runtime git clone on bare metal; bake it in so the container
# does not need network access at first boot.
RUN git clone --depth=1 https://github.com/phpsysinfo/phpsysinfo.git /home/birdnet/phpsysinfo \
    && rm -rf /home/birdnet/phpsysinfo/.git \
    && chown -R birdnet:birdnet /home/birdnet/phpsysinfo

# --- shims ------------------------------------------------------------------
# /usr/local/sbin and /usr/local/bin precede /usr/bin and /bin on PATH, so these
# win for normal callers. The absolute-path symlinks into /bin exist because the
# sudoers allowlist written by configure_caddy_php() pins /bin/systemctl and
# /bin/journalctl, and sudo resolves the literal path.
COPY docker/shims/systemctl docker/shims/journalctl docker/shims/reboot \
     docker/shims/service docker/shims/pulseaudio /usr/local/sbin/
RUN chmod 0755 /usr/local/sbin/systemctl /usr/local/sbin/journalctl \
                /usr/local/sbin/reboot /usr/local/sbin/service /usr/local/sbin/pulseaudio \
    && ln -sf /usr/local/sbin/systemctl /bin/systemctl \
    && ln -sf /usr/local/sbin/journalctl /bin/journalctl \
    && ln -sf /usr/local/sbin/reboot /usr/local/sbin/shutdown \
    && ln -sf /usr/local/sbin/reboot /usr/local/sbin/halt \
    && ln -sf /usr/local/sbin/pulseaudio /usr/local/bin/pulseaudio

COPY docker/avian-container-init.sh /usr/local/bin/avian-container-init
RUN chmod 0755 /usr/local/bin/avian-container-init

COPY docker/services /tmp/services
COPY docker/build-s6-tree.sh /tmp/build-s6-tree.sh

# --- normalise line endings -------------------------------------------------
# Git on Windows checks out CRLF by default (core.autocrlf=true). The build
# context is the working tree, so on a Windows host every script arrives with
# CRLF and dies inside the image with the memorable
#   /usr/bin/env: 'bash\r': No such file or directory
# .gitattributes prevents this for fresh clones, but not for a checkout made
# before it existed, and not if someone overrides it. Strip CR from everything a
# shell or cron parses. Idempotent, and a no-op on a correct LF checkout.
#
# Deliberately limited to shell and cron: PHP, Python, JS and JSON all parse
# CRLF perfectly well, and the interpreters are invoked explicitly rather than
# through a shebang, so rewriting them would be churn for no gain.
RUN find /home/birdnet/BirdNET-Pi /tmp/services /usr/local/sbin /usr/local/bin \
      \( -name '*.sh' -o -name '*.run' -o -name '*.cron' -o -name 'SERVICES' \
         -o -name 'gotty' -o -name 'bashrc' -o -name 'systemctl' -o -name 'journalctl' \
         -o -name 'reboot' -o -name 'service' -o -name 'pulseaudio' \
         -o -name 'avian-container-init' \) \
      -type f -print0 \
    | xargs -0 --no-run-if-empty sed -i 's/\r$//' \
    && sed -i 's/\r$//' /tmp/build-s6-tree.sh \
    && head -1 /home/birdnet/BirdNET-Pi/scripts/install_config.sh | od -c | head -2

# --- normalise directory modes ----------------------------------------------
# Do not trust the permissions the build context carried in. A Windows or
# OneDrive checkout has no POSIX modes for BuildKit to preserve, and what it
# synthesises is not always sane: scripts/ arrives as dr-xr-xr-x, with no owner
# write bit, so the `sudo -u birdnet ln -fs ... $my_dir/scripts` calls in
# create_necessary_dirs fail and the container refuses to boot.
#
# DIRECTORIES ONLY, and no recursive chown. Both matter for image size: every
# file touched by chmod or chown is copied up into this layer, so a
# `chown -R` plus `chmod -R` over the tree duplicated the 659MB app COPY and the
# 1.28GB venv into a 1.94GB layer of nothing but changed metadata. There are a
# few hundred directories and they cost kilobytes.
#
# Dropping the recursive chown is safe because COPY --chown already placed the
# whole tree as birdnet:birdnet; only the files the CRLF pass rewrote came out
# root-owned, and they are re-chowned below. Dropping the file chmod is safe
# because every mutable file is symlinked onto a volume by
# avian-container-init, which sets ownership and mode there; the files that stay
# in the image layer are code, models and assets, which are only ever read.
RUN find /home/birdnet/BirdNET-Pi -type d -exec chmod 0775 {} + \
    && find /home/birdnet/BirdNET-Pi \
         \( -name '*.sh' -o -name 'gotty' -o -name 'bashrc' \) -type f -print0 \
       | xargs -0 --no-run-if-empty chown birdnet:birdnet \
    && su -s /bin/bash birdnet -c 'touch /home/birdnet/BirdNET-Pi/scripts/.probe && rm /home/birdnet/BirdNET-Pi/scripts/.probe' \
    && echo "birdnet can write into the checkout: ok"

# Created here, owned by birdnet, so a fresh named volume mounted over it
# inherits that ownership from the image. Docker seeds an empty named volume
# from the image path, root:root included if we leave it to be auto-created.
# avian-container-init re-checks this at runtime, which is what covers bind
# mounts: those are never seeded from the image.
RUN install -d -o birdnet -g birdnet -m 0775 /home/birdnet/BirdSongs

# --- supervised services ----------------------------------------------------
RUN chmod +x /tmp/build-s6-tree.sh \
    && /tmp/build-s6-tree.sh /tmp/services \
    && rm -rf /tmp/services /tmp/build-s6-tree.sh

# --- build-time install steps ----------------------------------------------
# Only the steps that write into the image. Everything that touches a
# volume-backed path (directories, database, Caddyfile, icecast passwords) is
# deferred to avian-container-init, because those paths do not exist yet.
#
# RUN defaults to /bin/sh, which on Debian is dash. Sourcing install_lib.sh
# under dash is a parse error: config_icecast uses a bash array, and the whole
# file is parsed even though this layer only calls two other functions. Declared
# here rather than at the top of the stage so the expensive apt layers above
# keep their cache.
SHELL ["/bin/bash", "-c"]

RUN set -eux; \
    export HOME=/home/birdnet USER=birdnet my_dir=/home/birdnet/BirdNET-Pi; \
    . "$my_dir/scripts/install_lib.sh"; \
    install_scripts; \
    configure_caddy_php; \
    chmod g+rx /home/birdnet

# Pin php-fpm to the un-versioned socket path.
#
# update_caddyfile.sh discovers the socket by globbing /run/php/php*-fpm.sock and
# falls back to /run/php/php-fpm.sock when the glob finds nothing. On bare metal
# php-fpm is already running when that script executes, so the glob wins. In the
# container the Caddyfile is written by avian-container-init, which by design
# runs before any service starts, so the glob always finds nothing and the
# fallback is always what lands in the Caddyfile. Making the pool listen on
# exactly that path turns a guaranteed 502 on every .php request into a
# deterministic match, and keeps the glob correct too.
RUN sed -i 's|^listen = .*|listen = /run/php/php-fpm.sock|' /etc/php/8.2/fpm/pool.d/www.conf \
    && grep -n '^listen' /etc/php/8.2/fpm/pool.d/www.conf

# --- cron -------------------------------------------------------------------
# cleanup + weekly_report only. automatic_update.cron is deliberately omitted;
# see docker/services/cron.run for why.
RUN sed 's/\$USER/birdnet/g' /home/birdnet/BirdNET-Pi/templates/cleanup.cron >> /etc/crontab \
    && sed 's/\$USER/birdnet/g' /home/birdnet/BirdNET-Pi/templates/weekly_report.cron >> /etc/crontab

# --- runtime config ---------------------------------------------------------
# /command must be on PATH: that is where s6-overlay installs s6-svstat, s6-svc
# and s6-setuidgid. The s6 tarball adds it via /etc/profile, which a container
# process never reads, so setting PATH explicitly here without /command leaves
# the systemctl shim unable to query any service state (every unit reports
# "inactive" while running perfectly) and every run script unable to drop
# privileges.
ENV TZ=UTC \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    PATH="/command:/home/birdnet/BirdNET-Pi/birdnet/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VOLUME ["/config", "/data", "/home/birdnet/BirdSongs"]

# Only Caddy is published. icecast (8000), gotty (8080/8888) and streamlit
# (8501) all bind to localhost and are reached through Caddy's reverse proxies.
EXPOSE 80

HEALTHCHECK --interval=60s --timeout=10s --start-period=180s --retries=3 \
  CMD curl -fsS http://localhost/ >/dev/null || exit 1

ENTRYPOINT ["/init"]
