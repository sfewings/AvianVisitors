#!/usr/bin/env bash
# Build-time only: turn docker/services/SERVICES + docker/services/*.run into an
# s6-rc source tree at /etc/s6-overlay/s6-rc.d.
#
# Every service gets a paired s6-log logger so its output lands in
# /var/log/birdnet/<name>/current with an ISO-8601 stamp, which is what the
# journalctl shim tails. Without this, all output would be merged onto the
# container's stdout and the per-unit log view in the admin overlay would have
# nothing to show.
#
# All services depend on the init-avian oneshot, which seeds /config and /data
# and writes the Caddyfile. Nothing may start before that has finished.

set -euo pipefail

SRC_DIR=${1:?usage: build-s6-tree.sh <docker/services dir> [output prefix]}
# Optional prefix, so CI can assemble the tree somewhere harmless and assert on
# its shape without needing the real image. Empty in the Dockerfile.
PREFIX=${2:-}
RC=$PREFIX/etc/s6-overlay/s6-rc.d
LOGROOT=$PREFIX/var/log/birdnet

mkdir -p "$RC/user/contents.d"

# --- the init oneshot every service waits on ---------------------------------
mkdir -p "$RC/init-avian/dependencies.d"
echo oneshot > "$RC/init-avian/type"
# with-contenv is what exposes the container's environment (TZ, LATITUDE,
# REC_CARD, ...) to the script. Without it the oneshot runs with an almost empty
# environment and every compose-level setting would be silently ignored.
echo "/command/with-contenv /usr/local/bin/avian-container-init" > "$RC/init-avian/up"
# First boot walks the whole recordings volume to fix permissions; the s6-rc
# default timeout would kill it partway through on a large restore.
echo 0 > "$RC/init-avian/timeout-up"
# s6-overlay's own base bundle must be up first (it mounts /run, sets up
# /var/run, applies with-contenv, etc).
touch "$RC/init-avian/dependencies.d/base"
touch "$RC/user/contents.d/init-avian"

# --- one longrun + one logger per manifest entry -----------------------------
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac

  name=${line%%:*}
  enabled=${line#*:}

  run_src="$SRC_DIR/$name.run"
  if [ ! -f "$run_src" ]; then
    echo "build-s6-tree: no run script for '$name' at $run_src" >&2
    exit 1
  fi

  # An s6 pipeline only carries stdout. A run script that forgets to fold stderr
  # in still works, but its log file stays empty forever and the admin overlay's
  # log view for that unit shows nothing - a failure that is invisible until
  # someone actually goes looking for a log. Catch it at build time instead.
  if ! grep -q '^exec 2>&1$' "$run_src"; then
    echo "build-s6-tree: $run_src is missing 'exec 2>&1'; its stderr would never" >&2
    echo "               reach /var/log/birdnet/$name and the log view would be empty" >&2
    exit 1
  fi

  mkdir -p "$RC/$name/dependencies.d"
  echo longrun > "$RC/$name/type"
  install -m 0755 "$run_src" "$RC/$name/run"
  touch "$RC/$name/dependencies.d/init-avian"
  echo "$name-log" > "$RC/$name/producer-for"

  # Logger half of the pipeline.
  mkdir -p "$RC/$name-log/dependencies.d"
  echo longrun > "$RC/$name-log/type"
  echo "$name" > "$RC/$name-log/consumer-for"
  echo "$name-pipeline" > "$RC/$name-log/pipeline-name"
  touch "$RC/$name-log/dependencies.d/init-avian"
  # T = ISO 8601 timestamps, n5 = keep 5 rotated files, s2000000 = rotate at 2MB.
  # That caps each unit at ~12MB, which matters on an SD card.
  cat > "$RC/$name-log/run" <<EOF
#!/command/execlineb -P
s6-log -b n5 s2000000 T $LOGROOT/$name
EOF
  chmod 0755 "$RC/$name-log/run"

  mkdir -p "$LOGROOT/$name"

  # Adding the pipeline name (not the service name) to the bundle brings up
  # both halves together.
  if [ "$enabled" = "yes" ]; then
    touch "$RC/user/contents.d/$name-pipeline"
  fi
done < "$SRC_DIR/SERVICES"

# s6-log runs as root here; the log dirs are only read by the journalctl shim,
# which php-fpm reaches through sudo.
chmod -R 0755 "$LOGROOT"

echo "build-s6-tree: assembled $(find "$RC" -maxdepth 1 -mindepth 1 -type d | wc -l) s6-rc entries"
