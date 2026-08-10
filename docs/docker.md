# Running AvianVisitors in Docker

An alternative to [`newinstaller.sh`](../newinstaller.sh). Same application, same
web UI, packaged as one container instead of a systemd install that takes over
the machine.

Use the container if you want AvianVisitors alongside other services on a Pi you
already use for something else, or if you want upgrades and rollbacks to be
`docker compose pull` rather than a git pull plus a pip install. Use the
bare-metal installer if you want the appliance experience on a dedicated Pi:
mDNS at `birdnet.local`, an autologin console, and zram all come for free there
and are deliberately left out here.

**arm64 only.** The BirdNET model runs through a `tflite_runtime` wheel that is
published per architecture and per Python version; the image pins Debian
bookworm (Python 3.11) against the matching aarch64 wheel.

---

## 1. Prerequisites

A 64-bit Linux host with Docker and the compose plugin:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out and back in
```

Plug in the USB mic, then find its ALSA address **on the host**:

```bash
arecord -l
# card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
#      ^                                     ^
#      └── plughw:1,0 ───────────────────────┘
```

## 2. Configure

```bash
git clone -b avian-visitors https://github.com/Twarner491/AvianVisitors.git
cd AvianVisitors
cp .env.example .env
$EDITOR .env          # at minimum: LATITUDE, LONGITUDE, TZ, REC_CARD
mkdir -p config && sudo chown 1000:1000 config
```

## 3. Start

```bash
docker compose up -d
docker compose logs -f
```

First boot generates `config/birdnet.conf`, creates the database, and fixes
permissions on the volumes. Give it a couple of minutes.

- Collage: `http://<host>:8080/`
- Stock BirdNET-Pi UI: `http://<host>:8080/index.php`
- Admin overlay: the menu button, top right

---

## Building it yourself

```bash
docker buildx build --platform linux/arm64 -f docker/Dockerfile -t avianvisitors .
```

Building on the Pi itself works but is slow, mostly in the venv stage. Building
on an x86 machine needs `binfmt` emulation:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

---

## What lives where

| Path | Volume | Contents |
|---|---|---|
| `/config` | `./config` bind mount | `birdnet.conf`, the one file you may want to hand-edit |
| `/data` | `avian-data` | `birds.db`, `BirdDB.txt`, species lists, notification templates |
| `/home/birdnet/BirdSongs` | `avian-recordings` | Recordings, extractions, charts. This is the one that grows. |
| `/home/birdnet/BirdSongs/StreamData` | tmpfs | Raw 15s captures awaiting analysis. Deliberately not persisted. |

BirdNET-Pi keeps its mutable state *inside* its own checkout, and the paths are
hardcoded across dozens of scripts and the PHP UI. Rather than patch every
caller, the container seeds that state onto volumes and symlinks it back to the
paths the code expects. That work happens in
[`docker/avian-container-init.sh`](../docker/avian-container-init.sh).

The split between `/config`, `/data` and the recordings volume mirrors the
`required` and `optional` file lists in
[`scripts/backup_data.sh`](../scripts/backup_data.sh), which is upstream's own
definition of user data.

### Backups

`/config` and `/data` together are small and are what you actually need:

```bash
docker run --rm -v avian-data:/data -v "$PWD:/backup" debian:bookworm-slim \
  tar czf /backup/avian-data.tgz -C /data .
tar czf config.tgz config/
```

The recordings volume is optional and large. The in-app backup tool under
Tools also still works and produces an archive the bare-metal install can
restore.

---

## Settings: two places, one winner

Anything given a **non-empty** value in `.env` is written into `birdnet.conf` on
every container start and overrides the web UI.

That is the useful behaviour for things you want declared in compose, and a trap
for everything else. If you pin `CONFIDENCE` in `.env` and then change it in the
UI, your change survives until the next restart and is then quietly overwritten.
Pick one place per setting.

Leaving a key out of `.env`, or setting it to empty, hands it entirely to the UI.
That is why empty means "not set" rather than "set to blank": compose resolves
`CADDY_PWD: ${CADDY_PWD:-}` to an empty string rather than omitting it, so a
stricter rule would wipe your web password on every restart. The cost is that
you cannot clear a value back to empty from `.env`; do that in the UI, or edit
`config/birdnet.conf` and restart.

`AUTOMATIC_UPDATE` is forced to `0` and cannot be turned on. On bare metal it
git-pulls the checkout every Sunday; here the code is an image layer paired with
a venv built alongside it, so a self-updating checkout would only desynchronise
the two. Update with `docker compose pull && docker compose up -d`.

---

## How systemd is replaced

The web UI is built around systemd. [`scripts/service_controls.php`](../scripts/service_controls.php)
and [`avian/api/birdnet-status.php`](../avian/api/birdnet-status.php) shell out
to `systemctl` and `journalctl` to show service state, tail logs, and restart
units.

Rather than rewrite that UI, the image supervises everything with
[s6-overlay](https://github.com/just-containers/s6-overlay) and puts a
[`systemctl` shim](../docker/shims/systemctl) on `PATH` that maps the handful of
subcommands the UI actually uses onto `s6-svc`. A
[`journalctl` shim](../docker/shims/journalctl) tails the per-service `s6-log`
directories under `/var/log/birdnet/`. The result is that the Services and Logs
panels work unchanged.

The supervised set is declared in
[`docker/services/SERVICES`](../docker/services/SERVICES), one short run script
per process. Restart buttons in the UI work; Enable and Disable are no-ops,
because the service set is fixed at build time.

`reboot` maps to stopping the container, which `restart: unless-stopped` then
brings straight back. That is the closest honest equivalent, and closer to what
the button means than you might expect.

---

## What you give up versus bare metal

Worth knowing before you choose:

- **The System panel is partly fiction.** It reads `/proc/uptime`,
  `/proc/meminfo` and `/sys/class/thermal`, which inside a container report the
  host's values, the container's, or nothing, inconsistently. Nothing breaks;
  the numbers are just less meaningful than they look.
- **No mDNS.** There is no `birdnet.local`. Reach the container by host IP and
  port, or put your own reverse proxy in front.
- **No PulseAudio,** so `REC_CARD` must name a real ALSA device
  (`plughw:1,0`), not `default`. The init logs a warning and lists the visible
  capture cards if you get this wrong.
- **No illustration regeneration in the image.** `avian/scripts/` is excluded
  from the build context: it is a developer tool that calls the Gemini and eBird
  APIs. Run the pipeline on any machine per the
  [main README](../README.md#3-optional-restyle-the-illustrations), then mount
  the result over `/home/birdnet/BirdNET-Pi/avian/assets/illustrations`.
- **macOS and Windows hosts cannot use a USB mic at all.** Docker Desktop has no
  `/dev/snd` to forward. `RTSP_STREAM` is the only option there.

---

## Troubleshooting

**No detections, and the mic looks idle.**

```bash
docker compose exec avianvisitors journalctl -u birdnet_recording -n 50
docker compose exec avianvisitors cat /proc/asound/cards
```

The usual cause is a wrong `REC_CARD`. Card numbering can shift across host
reboots if you have more than one audio device; pin it by name instead, e.g.
`plughw:CARD=Device,DEV=0`.

**`arecord: main:830: audio open error: Device or resource busy`**

Something on the host already holds the mic. The container and the host cannot
both capture from it.

**Analysis service restarting in a loop.** Almost always memory. Raise
`MEM_LIMIT` in `.env`, or check:

```bash
docker compose exec avianvisitors journalctl -u birdnet_analysis -n 100
docker stats avianvisitors
```

**Permission errors on `./config`.** The container runs as uid 1000. If your
host user is not 1000, `sudo chown -R 1000:1000 config`.

**Everything looks stuck on first boot.** The first start walks the recordings
volume to fix ownership, which is slow if you restored a large backup. It runs
once and drops a marker at `/data/.permissions-done`.

**Start over.** This deletes every detection and recording:

```bash
docker compose down -v && rm -rf config
```
