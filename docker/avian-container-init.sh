#!/usr/bin/env bash
# First-boot and every-boot setup for the AvianVisitors container.
#
# Runs as the s6-rc "init-avian" oneshot; every supervised service depends on
# it, so nothing starts until this returns 0.
#
# The problem this solves: BirdNET-Pi keeps its mutable state *inside* the
# checkout (birdnet.conf, scripts/birds.db, BirdDB.txt, the species lists), and
# dozens of scripts plus the PHP UI hardcode those paths. In a container the
# checkout is a read-only-ish image layer that is replaced on every
# `docker compose pull`. So instead of relocating the state (which would mean
# patching every caller) we seed it onto volumes and symlink it back into the
# checkout at the paths everything already expects.
#
#   /config  -> birdnet.conf (small, hand-editable, bind-mounted by default)
#   /data    -> birds.db, BirdDB.txt, species lists, notification templates
#   ~/BirdSongs -> recordings, extractions, charts (its own volume)
#
# The file split mirrors the required/optional lists in scripts/backup_data.sh,
# which is upstream's own definition of "user data".

set -euo pipefail

export HOME=/home/birdnet
export USER=birdnet
export BIRDNET_USER=birdnet

my_dir=/home/birdnet/BirdNET-Pi
export my_dir

CONFIG_DIR=/config
DATA_DIR=/data
RECS_DIR_DEFAULT=/home/birdnet/BirdSongs

log() { echo "[avian-init] $*"; }
die() { echo "[avian-init] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Timezone
# ---------------------------------------------------------------------------
# tzlocal (used by the analysis and reporting code) reads /etc/timezone on
# Debian and fails if it disagrees with /etc/localtime. On bare metal
# install_birdnet.sh syncs them via timedatectl, which does not exist here.
setup_timezone() {
  local tz="${TZ:-UTC}"
  if [ ! -f "/usr/share/zoneinfo/$tz" ]; then
    log "unknown TZ '$tz', falling back to UTC"
    tz=UTC
  fi
  ln -snf "/usr/share/zoneinfo/$tz" /etc/localtime
  echo "$tz" > /etc/timezone
  log "timezone set to $tz"
}

# ---------------------------------------------------------------------------
# 2. Persist mutable state on volumes, symlinked back into the checkout
# ---------------------------------------------------------------------------
# "<path relative to the checkout>" - seeded empty on first boot if absent.
STATE_FILES=(
  BirdDB.txt
  IdentifiedSoFar.txt
  apprise.txt
  body.txt
  exclude_species_list.txt
  include_species_list.txt
  confirmed_species_list.txt
  whitelist_species_list.txt
  scripts/birds.db
  scripts/disk_check_exclude.txt
  scripts/blacklisted_images.txt
)

link_state() {
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$DATA_DIR/scripts"

  local rel base target
  for rel in "${STATE_FILES[@]}"; do
    base="$DATA_DIR/$rel"
    target="$my_dir/$rel"

    # Seed from whatever the image shipped, if anything. If the image shipped
    # nothing, deliberately leave the volume path ABSENT rather than touching an
    # empty file, so the symlink dangles until something writes through it.
    #
    # An empty placeholder looks harmless and is not. generate_BirdDB in
    # scripts/install_lib.sh branches on `[ -f BirdDB.txt ]`: with a placeholder
    # it takes the "file exists, add the header" path, which is
    # `sed '1 i\...'` - and sed inserts nothing into a file with no line 1. The
    # header silently never gets written. Absent, the first branch runs instead
    # and touch+tee create the file through the symlink correctly. The same
    # first-run-detection logic exists all over upstream, so let it see the truth.
    if [ ! -e "$base" ] && [ -f "$target" ] && [ ! -L "$target" ]; then
      log "seeding $rel from the image"
      cp -a "$target" "$base"
    fi

    mkdir -p "$(dirname "$target")"
    # -n so we replace the symlink itself rather than writing through an
    # existing one, and never leave a stale regular file behind.
    rm -f "$target"
    ln -sfn "$base" "$target"
  done

  # birdnet.conf lives in /config, not /data: it is the one file a user is
  # expected to open in an editor. Symlink it into both places the code looks.
  mkdir -p /etc/birdnet
  ln -sfn "$CONFIG_DIR/birdnet.conf" "$my_dir/birdnet.conf"
  ln -sfn "$CONFIG_DIR/birdnet.conf" /etc/birdnet/birdnet.conf

  chown -R birdnet:birdnet "$DATA_DIR" "$CONFIG_DIR"
}

# ---------------------------------------------------------------------------
# 3. Generate birdnet.conf on first boot
# ---------------------------------------------------------------------------
# install_config.sh is reused verbatim, but only on first boot.
#
# It looks idempotent - the config generation is guarded by an existence check -
# but the last two lines are not: it re-derives firstrun.ini and, more
# importantly, overwrites body.txt with the stock notification template. On bare
# metal that runs once at install time and nobody notices. Run it on every
# container start and a user's customised notification body would be silently
# reset each time the container restarts.
#
# $my_dir/birdnet.conf is already a symlink into /config by this point, so the
# heredoc inside writes straight through to the volume.
seed_config() {
  if [ -f "$CONFIG_DIR/birdnet.conf" ]; then
    log "existing birdnet.conf found in /config"
    return 0
  fi

  log "no birdnet.conf yet, generating a default one"
  ( cd "$my_dir/scripts" && HOSTNAME="${HOSTNAME:-birdnet}" ./install_config.sh )

  if [ ! -f "$CONFIG_DIR/birdnet.conf" ]; then
    die "install_config.sh did not produce $CONFIG_DIR/birdnet.conf"
  fi
}

# ---------------------------------------------------------------------------
# 4. Apply environment overrides
# ---------------------------------------------------------------------------
# Contract: any variable in this list with a NON-EMPTY value in the container
# environment is written into birdnet.conf on every boot. Anything unset or
# empty is left alone and stays owned by the web UI.
#
# Empty has to mean "not set" rather than "set to blank". docker-compose.yml
# writes `CADDY_PWD: ${CADDY_PWD:-}`, and compose resolves that to an empty
# string rather than omitting the variable, so a strict is-it-defined test would
# blank out the web password on every restart for anyone who set it in the UI.
# The same applies to BIRDNETPI_URL, BIRDWEATHER_ID and RTSP_STREAM.
#
# The cost is that you cannot clear a value back to empty from the environment;
# do that in the UI, or edit config/birdnet.conf directly.
#
# The other consequence, worth knowing before you file a bug: if you pin
# CONFIDENCE in docker-compose.yml and then change it in the web UI, your change
# survives until the next restart and is then overwritten. Set it in one place
# or the other, not both.
CONFIG_KEYS=(
  SITE_NAME LATITUDE LONGITUDE
  MODEL SF_THRESH
  BIRDWEATHER_ID
  CADDY_PWD ICE_PWD BIRDNETPI_URL STOCK_UI_PORT
  RTSP_STREAM RTSP_STREAM_TO_LIVESTREAM
  REC_CARD CHANNELS
  CONFIDENCE SENSITIVITY OVERLAP
  RECORDING_LENGTH EXTRACTION_LENGTH AUDIOFMT
  PRIVACY_THRESHOLD
  DATABASE_LANG
  FULL_DISK PURGE_THRESHOLD MAX_FILES_SPECIES
  COLOR_SCHEME IMAGE_PROVIDER INFO_SITE
  FLICKR_API_KEY FLICKR_FILTER_EMAIL
  RARE_SPECIES_THRESHOLD
  HEARTBEAT_URL
  APPRISE_NOTIFICATION_TITLE
  APPRISE_NOTIFY_EACH_DETECTION
  APPRISE_NOTIFY_NEW_SPECIES
  APPRISE_NOTIFY_NEW_SPECIES_EACH_DAY
  APPRISE_WEEKLY_REPORT
  LogLevel_BirdnetRecordingService
  LogLevel_LiveAudioStreamService
  LogLevel_SpectrogramViewerService
)

set_conf() {
  local key="$1" val="$2" file="$CONFIG_DIR/birdnet.conf"

  # Double-quote the value, matching how scripts/config.php writes the free-text
  # keys. Every consumer either `source`s the file or strips surrounding double
  # quotes (see read_conf_summary in avian/api/birdnet-status.php), so this is
  # safe for numeric keys too. Escape the four characters bash would otherwise
  # interpret inside double quotes, since RTSP URLs and passwords can contain
  # them.
  local esc="$val"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//\$/\\\$}"
  esc="${esc//\`/\\\`}"

  # Rewritten in bash rather than with sed: values legitimately contain slashes,
  # ampersands and backslashes, all of which sed treats specially in a
  # replacement.
  local tmp line found=0
  tmp=$(mktemp)
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line == "$key="* ]]; then
      printf '%s="%s"\n' "$key" "$esc"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done < "$file" > "$tmp"
  [ "$found" -eq 0 ] && printf '%s="%s"\n' "$key" "$esc" >> "$tmp"

  # Copy the contents rather than mv the file, so we write through the symlink
  # into /config and keep the inode, ownership and mode the UI expects.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

apply_env_overrides() {
  local key
  for key in "${CONFIG_KEYS[@]}"; do
    if [ -n "${!key:-}" ]; then
      # Passwords and API keys go through here; log the key, never the value.
      log "config: $key from environment"
      set_conf "$key" "${!key}"
    fi
  done

  # Non-negotiable in a container. The bare-metal installer wires up a weekly
  # `git pull` of the checkout; here the checkout is an image layer and
  # updating means pulling a new image, so a self-updating tree would only
  # desynchronise the code from the venv baked alongside it.
  set_conf AUTOMATIC_UPDATE 0

  # BIRDNET_USER is baked into the image; a restored backup from a bare-metal
  # install would otherwise carry the old username and break every path.
  set_conf BIRDNET_USER birdnet

  chown birdnet:birdnet "$CONFIG_DIR/birdnet.conf"
  chmod 0664 "$CONFIG_DIR/birdnet.conf"
}

# ---------------------------------------------------------------------------
# 5. Audio sanity check
# ---------------------------------------------------------------------------
# Not fatal: a misconfigured mic should leave you with a working web UI and a
# clear log line, not a container that refuses to boot.
check_audio() {
  source "$CONFIG_DIR/birdnet.conf"

  if [ -n "${RTSP_STREAM:-}" ]; then
    log "audio source: RTSP (${RTSP_STREAM})"
    return 0
  fi

  if [ ! -d /proc/asound ] || [ -z "$(ls -A /dev/snd 2>/dev/null)" ]; then
    log "WARNING: no sound devices visible in the container."
    log "         Pass the host mic through with 'devices: [/dev/snd:/dev/snd]'"
    log "         in docker-compose.yml, or set RTSP_STREAM to use a network"
    log "         audio source instead. Detection will not run until then."
    return 0
  fi

  # What the container can actually capture from. /proc/asound is the host's
  # ALSA state and is visible even without /dev/snd passed through, so the
  # authoritative test is the device node: /dev/snd/pcmC<card>D<dev>c is the
  # capture endpoint arecord opens.
  log "capture devices visible to the container:"
  local found=0 n nm
  while read -r n nm; do
    if [ -e "/dev/snd/pcmC${n}D0c" ]; then
      log "  card $n [$nm]  -> plughw:${n},0  or  plughw:CARD=${nm},DEV=0"
      found=1
    else
      log "  card $n [$nm]  (no capture node; playback only, or not passed through)"
    fi
  done < <(awk '/^ *[0-9]+ \[/ { nm=$2; gsub(/[][]/,"",nm); print $1, nm }' \
             /proc/asound/cards 2>/dev/null)
  [ "$found" -eq 1 ] || log "  (none with a capture node)"

  # Validate REC_CARD against that, rather than reporting success and letting
  # arecord fail later with "audio open error: No such file or directory",
  # which says nothing about which card it wanted or what exists.
  local rc="${REC_CARD:-default}" want=""
  case "$rc" in
    default)
      log "WARNING: REC_CARD is 'default'. That routes through PulseAudio, which"
      log "         this container deliberately does not run. Set it to one of"
      log "         the devices listed above."
      return 0
      ;;
    *CARD=*)
      # plughw:CARD=UM02,DEV=0 - resolve the name to a card number.
      nm=${rc#*CARD=}; nm=${nm%%,*}
      want=$(awk -v want="$nm" '/^ *[0-9]+ \[/ { c=$2; gsub(/[][]/,"",c);
               if (c == want) print $1 }' /proc/asound/cards 2>/dev/null)
      if [ -z "$want" ]; then
        log "WARNING: REC_CARD names card '$nm', which is not present."
        return 0
      fi
      ;;
    *:[0-9]*)
      want=${rc##*:}; want=${want%%,*}
      ;;
    *)
      log "audio source: ALSA device $rc (unrecognised form, not validated)"
      return 0
      ;;
  esac

  if [ -e "/dev/snd/pcmC${want}D0c" ]; then
    log "audio source: ALSA device $rc (card $want, capture node present)"
  else
    log "WARNING: REC_CARD is '$rc' but /dev/snd/pcmC${want}D0c does not exist,"
    log "         so arecord will fail with 'audio open error: No such file or"
    log "         directory'. Pick one of the cards listed above."
    log "         Card numbers can change across reboots and when USB devices"
    log "         are re-plugged; the plughw:CARD=<name>,DEV=0 form is stable."
  fi
}

# ---------------------------------------------------------------------------
# 5b. Illustration assets
# ---------------------------------------------------------------------------
# avian/assets is ~491MB and is excluded from the image (.dockerignore); it
# arrives as a read-only bind mount instead. Checked here so a missing mount
# produces one actionable message, rather than surfacing later as
# "Missing webroot source: .../avian/assets/favicon.png" from link_webroot.sh,
# which is what create_necessary_dirs would otherwise abort on.
#
# Fatal rather than a warning: without illustrations the collage has nothing to
# draw, so a container that "started fine" would be more confusing than one
# that says why it did not.
check_assets() {
  local dir="$my_dir/avian/assets"

  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    log "FATAL: $dir is missing or empty."
    log ""
    log "  The illustration assets are not in the image. Mount them:"
    log ""
    log "    volumes:"
    log "      - ./avian/assets:/home/birdnet/BirdNET-Pi/avian/assets:ro"
    log ""
    log "  docker-compose.yml in this repo already does this. If you are"
    log "  running docker directly, add the -v yourself, or set ASSETS_DIR"
    log "  to point at a different set of illustrations."
    die "illustration assets not mounted"
  fi

  # favicon.png specifically, because link_webroot.sh treats it as mandatory.
  if [ ! -f "$dir/favicon.png" ]; then
    die "$dir is mounted but has no favicon.png; is it the right directory?"
  fi

  local n
  n=$(ls -1 "$dir/illustrations" 2>/dev/null | wc -l)
  log "assets: $n illustrations, mounted $([ -w "$dir" ] && echo read-write || echo read-only)"
  if [ "$n" -eq 0 ]; then
    log "assets: WARNING no illustrations found; the collage will fall back to"
    log "        photo cutouts, and to nothing at all where those are missing."
  fi
}

# ---------------------------------------------------------------------------
# 6. Directories, database, web root, services config
# ---------------------------------------------------------------------------
# These run on every boot rather than at build time because they all write into
# volume-backed paths, which do not exist while the image is being built.
# Docker creates a mount point that does not exist in the image as root:root,
# and a bind mount always arrives with the host's ownership regardless of what
# the image had. Either way create_necessary_dirs, which runs everything through
# `sudo -u birdnet`, cannot mkdir inside a root-owned directory.
#
# Only the mount points themselves, never recursive: the recordings volume can
# hold tens of thousands of files and this runs on every boot. The one-time
# recursive pass is fix_permissions, guarded by a marker.
ensure_data_roots() {
  local d
  for d in "$RECS_DIR" "$DATA_DIR" "$DATA_DIR/scripts" "$CONFIG_DIR"; do
    mkdir -p "$d"
    if [ "$(stat -c '%U' "$d")" != birdnet ]; then
      log "taking ownership of $d"
      chown birdnet:birdnet "$d"
    fi
    # g+w so php-fpm (running as caddy, a member of the birdnet group) can write.
    chmod g+rwx "$d" 2>/dev/null || true
  done
}

setup_runtime() {
  source "$CONFIG_DIR/birdnet.conf"
  source "$my_dir/scripts/install_lib.sh"

  export RECS_DIR="${RECS_DIR:-$RECS_DIR_DEFAULT}"

  ensure_data_roots

  # These functions are shared with the bare-metal installer, which runs without
  # errexit and tolerates individual symlink failures. Honour the environment
  # they were written for: one dangling `ln` must not stop the container from
  # booting. Anything genuinely fatal calls exit itself (see the webroot check
  # in create_necessary_dirs), which still propagates.
  set +e

  # Refreshed on every boot: these symlinks point into the image layer, so an
  # image update can add or move files behind them.
  create_necessary_dirs
  generate_BirdDB

  # createdb.sh opens with DROP TABLE IF EXISTS detections, so it must only ever
  # run when there is no database to lose.
  if [ ! -s "$DATA_DIR/scripts/birds.db" ]; then
    log "creating a fresh detections database"
    USER=birdnet HOME=/home/birdnet "$my_dir/scripts/createdb.sh"
  else
    log "existing database found, leaving it alone"
  fi

  # Regenerated each boot so a DATABASE_LANG change takes effect on restart.
  "$my_dir/scripts/install_language_label.sh"

  config_icecast

  # Rewrites /etc/caddy/Caddyfile from the current BIRDNETPI_URL and CADDY_PWD,
  # and is the single source of truth for serving the collage at / rather than
  # the stock index.php. Caddy has not started yet, so its reload is a no-op.
  "$my_dir/scripts/update_caddyfile.sh"

  # Recursive, so first boot only. On a mature install ${RECS_DIR} holds tens of
  # thousands of extractions and walking it would add minutes to every restart.
  # Delete this marker to force a re-run if you ever restore a backup taken
  # under a different uid.
  #
  # Scoped to ${RECS_DIR}, rather than the bare-metal installer's fix_permissions
  # and chown_things which also walk $my_dir. Two reasons: the checkout's
  # ownership and modes are already set at build time, and avian/assets inside it
  # is a read-only bind mount, so recursing over it would emit a
  # "Read-only file system" error per file - hundreds of lines of noise on every
  # first boot, for work that is not needed.
  if [ ! -f "$DATA_DIR/.permissions-done" ]; then
    log "first boot: fixing ownership and permissions under $RECS_DIR"
    chown -R birdnet:birdnet "$RECS_DIR"
    chmod -R g+rw "$RECS_DIR"
    touch "$DATA_DIR/.permissions-done"
  else
    # Cheap every-boot equivalent: only the mount points themselves, which
    # Docker creates as root when a named volume is first attached.
    chown birdnet:birdnet "$RECS_DIR" "$DATA_DIR" "$CONFIG_DIR" 2>/dev/null
  fi

  set -e
}

# ---------------------------------------------------------------------------
# 7. Optional services
# ---------------------------------------------------------------------------
# The MQTT bridge is defined in docker/services/SERVICES as "no", so s6-rc knows
# about it and puts a servicedir in the scandir but does not start it at boot.
# Starting it here, only when a broker is configured, keeps
# `systemctl is-active avian_mqtt` truthful: inactive means genuinely not
# running, rather than a process idling against a broker that was never set.
#
# Deliberately not driven by birdnet.conf. The bridge is a container-level
# integration, not a BirdNET-Pi setting, and putting it in the conf would leak
# broker credentials into the file the web UI displays.
start_optional_services() {
  if [ -z "${MQTT_BROKER:-}" ]; then
    log "MQTT bridge: MQTT_BROKER unset, leaving avian_mqtt stopped"
    return 0
  fi

  if [ ! -d /run/service/avian_mqtt ]; then
    log "MQTT bridge: WARNING avian_mqtt not found in the supervision tree"
    return 0
  fi

  # The container-appropriate MQTT_PI_URL default lives in the run script, not
  # here: this image sets S6_KEEP_ENV=1, which makes with-contenv a pass-through
  # with no container_environment directory to write a late-bound variable into.
  log "MQTT bridge: starting avian_mqtt (broker ${MQTT_BROKER})"

  # Both halves, logger first, and with s6-svc rather than s6-rc.
  #
  # s6-svc because s6-rc cannot be used from here at all: init-avian is itself
  # part of the boot transaction, which holds the s6-rc lock, so
  # `s6-rc -u change avian_mqtt-pipeline` dies with
  # "fatal: unable to take locks: Resource busy" and the bridge never starts.
  #
  # Both halves because each service is the producer of a producer/consumer pair
  # with its s6-log logger. Starting only the producer leaves its stdout as a
  # pipe with no reader: nothing reaches the log view, and once the pipe buffer
  # fills the bridge blocks on write and silently stops publishing. The logger
  # goes first so a reader is already attached.
  #
  # Expect one "poll error: Connection refused" in the log. init-avian runs
  # before Caddy starts, so the bridge's first poll of localhost has nothing to
  # talk to yet; it retries every MQTT_POLL_SECONDS and recovers by itself.
  s6-svc -u /run/service/avian_mqtt-log || log "MQTT bridge: logger failed to start"
  s6-svc -u /run/service/avian_mqtt     || log "MQTT bridge: failed to start"
}

# ---------------------------------------------------------------------------
main() {
  log "starting container init"
  setup_timezone
  link_state
  seed_config
  apply_env_overrides
  check_audio
  check_assets
  setup_runtime
  start_optional_services
  log "init complete"
}

# Guarded so the functions above can be sourced and exercised in isolation,
# matching the convention in scripts/link_webroot.sh.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
