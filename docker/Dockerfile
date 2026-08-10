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

# --- supervised services ----------------------------------------------------
COPY docker/services /tmp/services
COPY docker/build-s6-tree.sh /tmp/build-s6-tree.sh
RUN chmod +x /tmp/build-s6-tree.sh \
    && /tmp/build-s6-tree.sh /tmp/services \
    && rm -rf /tmp/services /tmp/build-s6-tree.sh

# --- build-time install steps ----------------------------------------------
# Only the steps that write into the image. Everything that touches a
# volume-backed path (directories, database, Caddyfile, icecast passwords) is
# deferred to avian-container-init, because those paths do not exist yet.
RUN set -eux; \
    export HOME=/home/birdnet USER=birdnet my_dir=/home/birdnet/BirdNET-Pi; \
    . "$my_dir/scripts/install_lib.sh"; \
    install_scripts; \
    configure_caddy_php; \
    chmod g+rx /home/birdnet

# --- cron -------------------------------------------------------------------
# cleanup + weekly_report only. automatic_update.cron is deliberately omitted;
# see docker/services/cron.run for why.
RUN sed 's/\$USER/birdnet/g' /home/birdnet/BirdNET-Pi/templates/cleanup.cron >> /etc/crontab \
    && sed 's/\$USER/birdnet/g' /home/birdnet/BirdNET-Pi/templates/weekly_report.cron >> /etc/crontab

# --- runtime config ---------------------------------------------------------
ENV TZ=UTC \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    PATH="/home/birdnet/BirdNET-Pi/birdnet/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VOLUME ["/config", "/data", "/home/birdnet/BirdSongs"]

# Only Caddy is published. icecast (8000), gotty (8080/8888) and streamlit
# (8501) all bind to localhost and are reached through Caddy's reverse proxies.
EXPOSE 80

HEALTHCHECK --interval=60s --timeout=10s --start-period=180s --retries=3 \
  CMD curl -fsS http://localhost/ >/dev/null || exit 1

ENTRYPOINT ["/init"]
