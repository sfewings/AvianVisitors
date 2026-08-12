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
| `…/avian/assets` | `${ASSETS_DIR}` bind mount, read-only | Illustrations, photo cutouts, sketches. **Required.** |

### Illustration assets are not in the image

`avian/assets` is about 491MB (420MB of illustrations, 62MB of cutouts, 11MB of
sketches), so it is excluded from the build context and bind mounted read-only
instead:

```yaml
    volumes:
      - ${ASSETS_DIR:-./avian/assets}:/home/birdnet/BirdNET-Pi/avian/assets:ro
```

Two things this buys. A rebuild no longer re-copies half a gigabyte into a layer.
And a regenerated set drops in by pointing `ASSETS_DIR` at it and restarting.

With one caveat that is easy to trip over: **the collage places birds by
silhouette, and the silhouettes are not in the mount.**
[`build_masks.py`](../avian/scripts/build_masks.py) writes `dims.json` and
`masks.json` into `avian/frontend/`, which is still in the image. A species with
no entry in `masks.json` is dropped from the collage entirely, illustration
present or not: [`apt.js`](../avian/frontend/apt.js) does
`if (!mask) return null` and filters it out.

So swapping `ASSETS_DIR` for a set of new species shows you nothing new until you
also run `cutout.py` and `build_masks.py` and rebuild the image. Restart alone is
enough only for *restyled* versions of species already in `masks.json`, where the
slugs are unchanged. Either mount `avian/frontend` too if you want to iterate
without rebuilding, or accept a `docker compose build` as part of regenerating.

Read-only is safe because nothing served ever writes there.
[`cutout.php`](../avian/api/cutout.php) reads the PNGs and writes only to the
system temp directory.

**The container refuses to start without this mount.** Deliberately: without
illustrations the collage has nothing to draw, so a container that appeared to
start normally would be more confusing than one that says why it did not. The
check is in `avian-container-init` and names the volume line you need. Without
it the failure would surface as `Missing webroot source: .../favicon.png` from
[`link_webroot.sh`](../scripts/link_webroot.sh), which is a good deal less
helpful.

If you run `docker` directly rather than through compose, the `-v` is on you:

```bash
-v "$PWD/avian/assets:/home/birdnet/BirdNET-Pi/avian/assets:ro"
```

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

## The two web UIs, on separate ports

There are two front ends in this repo, both served from the same Caddy web root:

- `avian/frontend/index.html`, the collage
- `homepage/index.php`, the stock BirdNET-Pi interface

By default the collage owns `/` and the stock UI sits at `/index.php`, because
[`update_caddyfile.sh`](../scripts/update_caddyfile.sh) overrides
`php_fastcgi`'s `try_files` to prefer `index.html`.

Set `STOCK_UI_PORT` to also give the stock UI a root of its own:

```bash
STOCK_UI_PORT=8081        # container port
STOCK_UI_HOST_PORT=8081   # host side, if you want it elsewhere
```

| URL | UI |
|---|---|
| `http://<host>:8080/` | Collage |
| `http://<host>:8080/index.php` | Stock UI (still works) |
| `http://<host>:8081/` | Stock UI at its own root |

Both sites share one web root and one snippet, so the live stream, `/stats`,
`/log`, `/terminal` and any `CADDY_PWD` basic auth apply identically on both. The
only difference between them is which index file `/` resolves to: port 80
overrides `try_files` to prefer `index.html`, port 8081 keeps Caddy's default,
which prefers `index.php`.

Leaving `STOCK_UI_PORT` empty disables the second site. Publishing the port with
the site disabled is harmless; connections are simply refused.

Worth knowing if you put this behind the reverse proxy described below: the
second site is a *separate port*, so it needs its own `location` block and
`proxy_pass` to `192.168.1.133:8081`. Nothing about it is reachable through the
`/birds/` prefix.

### Why this lives in update_caddyfile.sh

It has to. `avian-container-init` runs that script on every boot, so a
hand-written second site in `/etc/caddy/Caddyfile` would be erased on restart.

The script previously duplicated its whole site body between the with-password
and without-password branches; a second site would have made that four copies of
the same twenty lines. It now emits a Caddy snippet (`(birdnet_common)`) that
both sites import. Verified behaviour-preserving by adapting the old and new
generated Caddyfiles to JSON with `caddy adapt` and diffing: identical with
`STOCK_UI_PORT` empty, both with and without `CADDY_PWD`, once bcrypt's random
salt is normalised.

---

## Optional: the MQTT bridge

[`avian/forwarding/mqtt-bridge.py`](../avian/forwarding/mqtt-bridge.py) polls the
detections API and publishes each newly heard species to MQTT as JSON under
`<MQTT_TOPIC_PREFIX>/<species-slug>`, for Home Assistant and similar. It ships
in the image and `paho-mqtt` is already in the venv, so there is nothing to
install.

It runs **only if `MQTT_BROKER` is set.** Leave it blank and the service stays
genuinely stopped rather than idling:

```bash
docker compose exec avianvisitors systemctl is-active avian_mqtt   # inactive
```

To enable it, in `.env`:

```bash
MQTT_BROKER=homeassistant.local
MQTT_PORT=1883
MQTT_USER=
MQTT_PASSWORD=
MQTT_TOPIC_PREFIX=birdnet
MQTT_POLL_SECONDS=60
```

then `docker compose up -d`. Published payloads are the API's own species
objects:

```
birdnet/cacatua-roseicapilla {"sci":"Cacatua roseicapilla","com":"Galah","n":1,
  "best_conf":0.88,"last_seen":"2026-08-11 15:24:47","top_file":"galah.mp3",...}
```

Watch it with `docker compose exec avianvisitors journalctl -u avian_mqtt -n 50`.

Unlike the settings in `.env` that feed `birdnet.conf`, these are **not** written
to the config file. The bridge is a container-level integration rather than a
BirdNET-Pi setting, and the broker password has no business in a file the web UI
displays.

Three things worth knowing:

- **A restart re-publishes.** Dedup is in-memory, so anything still inside the
  poll window is emitted again after a restart. Harmless for sensors, worth
  knowing if you drive automations off it.
- **One `poll error: Connection refused` at startup is expected.** The bridge is
  started by `avian-container-init`, which runs before Caddy, so its first poll
  has nothing to talk to. It retries and recovers by itself.
- **`MQTT_PI_URL` defaults to Caddy on localhost** inside the container, rather
  than the script's bare-metal `birdnet.local` default which does not resolve
  there. Override it if you want the bridge to poll a different station.

### Why it is wired the way it is

Two constraints made this less obvious than it looks, both worth recording since
they apply to any future optional service:

`avian_mqtt` is listed as `no` in
[`docker/services/SERVICES`](../docker/services/SERVICES), so s6-rc knows it and
puts a servicedir in the scandir but does not start it at boot. The init then
starts it on demand. That is what keeps `is-active` truthful in both states.

It is started with **`s6-svc`, not `s6-rc`**, and **both halves of the pipeline
are started, logger first**. `s6-rc` cannot be used from `init-avian` at all:
the init is itself part of the boot transaction, which holds the s6-rc lock, so
the call dies with `fatal: unable to take locks: Resource busy`. And starting
only the producer leaves its stdout a pipe with no reader, so nothing reaches
the log view and the bridge eventually blocks on write once the buffer fills and
stops publishing with no error anywhere.

---

## Behind a reverse proxy, at a subpath

For publishing the collage on the internet through an existing nginx box, while
the BirdNET Pi itself stays on the LAN. The worked example serves
`https://example.org/birds/` from a container on `192.168.1.133`, proxied by
nginx on `192.168.1.131`.

The collage is written with relative `./` URLs throughout, so this needs no
response-body rewriting, no sub-filters, and no `--base-href` equivalent. Two
absolute URLs used to break it and were made relative
([`apt.js`](../avian/frontend/apt.js) `./stream`, and the "back to collage"
control in [`index.html`](../avian/frontend/index.html)), so a plain
prefix-stripping proxy is now sufficient.

### Do not configure this in the Caddyfile

`avian-container-init` runs
[`update_caddyfile.sh`](../scripts/update_caddyfile.sh) on **every container
boot**, which rewrites `/etc/caddy/Caddyfile` from scratch. Hand edits are
silently destroyed on the next restart. All proxy configuration belongs in
nginx.

### Container side

Two settings in `.env`:

```bash
# MUST stay empty. update_caddyfile.sh writes `http:// ${BIRDNETPI_URL} {`, so
# setting it makes Caddy answer for that hostname only. nginx forwards
# Host: example.org, which would then 404.
BIRDNETPI_URL=

# Also leave empty. It would put basic auth on /stream, which breaks the
# collage's live-audio button for every visitor. The nginx deny rules below
# protect the admin surface instead, without gating the public page.
CADDY_PWD=
```

And publish on port 80 in `docker-compose.yml`, so `proxy_pass` needs no port:

```yaml
    ports:
      - "80:80"        # instead of the default 8080:80
```

### nginx side

The complete `/etc/nginx/sites-available/default`. Nothing needs adding to
`/etc/nginx/nginx.conf`: the `http { }` block lives there and already
`include`s this file, which is why this file contains only a `server` block.

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name example.org;

    root /var/www/html;
    index index.html index.nginx-debian.html;

    # ---- whatever else this host already serves -------------------------
    location / {
        try_files $uri $uri/ =404;
    }

    # ---- AvianVisitors ---------------------------------------------------
    # Order does not matter for correctness: nginx evaluates regex locations
    # before prefix ones, so the deny and stream blocks win over /birds/.

    # /birds without the trailing slash leaves the browser resolving every
    # relative asset against /, so nothing loads. This redirect is essential,
    # not cosmetic: `location /birds/` does not match a request for `/birds`.
    location = /birds {
        return 301 /birds/;
    }

    # Admin and remote-control surface, denied at the edge. None of these
    # require authentication by default:
    #   avian/api/config.php          rewrites birdnet.conf, restarts services
    #   avian/api/birdnet-status.php  restarts services on POST
    #   avian/api/cutout.php          shells out
    #   /terminal                     gotty -w, a writable web shell
    #   /scripts                      serves adminer.php, a full DB admin tool
    #   /phpsysinfo, /Processed       host detail and raw recordings
    #   /stats, /log                  stock UI's streamlit and gotty views
    # Reach all of it on the LAN instead, at http://192.168.1.133/ directly.
    #
    # This is a denylist: a new API endpoint added later is public by default.
    # Prefer an allowlist if the API surface grows.
    location ~ ^/birds/(avian/api/(config|birdnet-status|cutout)\.php|terminal|scripts|phpsysinfo|Processed|log|stats)(/|$) {
        return 404;
    }

    # Live audio. icecast returns an endless response, so buffering must be off
    # or nginx accumulates it and the player never starts. Matched on the path,
    # so the cache-busting ?t= query string is irrelevant here.
    location = /birds/stream {
        proxy_pass         http://192.168.1.133/stream;
        proxy_set_header   Host $host;
        proxy_buffering    off;
        proxy_read_timeout 24h;
    }

    location /birds/ {
        # The trailing slash on proxy_pass is what strips the /birds/ prefix.
        # Without it nginx forwards /birds/... verbatim and Caddy 404s, because
        # the web root has no "birds" directory. With it, the container is
        # served as though at the root of its own host, and the collage's
        # relative ./ URLs resolve correctly browser-side.
        proxy_pass http://192.168.1.133/;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Empty Connection header enables upstream keepalive on HTTP/1.1.
        # No $connection_upgrade map is needed: the collage is fetch/poll only,
        # and the WebSocket consumers (/stats, /log, /terminal) are denied above.
        proxy_http_version 1.1;
        proxy_set_header   Connection "";

        # Chart and spectrogram regeneration is slow on a Pi under analysis load.
        proxy_read_timeout 300s;
    }
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

### If you later expose /stats or /log

Those two are WebSocket apps and need the upgrade headers, which require a
`map` in the `http` block. Do not edit `nginx.conf`: `conf.d/*.conf` is included
*inside* `http`, so a drop-in works and survives package upgrades.

```bash
echo 'map $http_upgrade $connection_upgrade { default upgrade; "" close; }' \
  | sudo tee /etc/nginx/conf.d/websocket-upgrade.conf
```

Then in the `/birds/` block replace `proxy_set_header Connection "";` with:

```nginx
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
```

### What ends up public

Reachable from the internet: the collage, its illustrations and detection list,
per-detection audio and spectrograms (served through `recording.php` and
`spectrogram.php`, both of which reject `..` and exclude `/` from their
filename regex), and the live stream.

LAN-only: settings, service restarts, logs, the system panel, the stock
BirdNET-Pi tools, the web terminal and the database admin page.

`/birds/index.php` still loads the stock UI, and its Tools links point at the
denied `/stats` and `/log`, so they 404 rather than degrade gracefully. Add
`index\.php` to the deny regex to keep the stock UI off the internet entirely.

### Checking it

```bash
curl -sI  https://example.org/birds          # expect 301 -> /birds/
curl -s   https://example.org/birds/ | head -6   # expect the collage <title>
curl -so /dev/null -w '%{http_code}\n' https://example.org/birds/avian/api/menu.php      # 200
curl -so /dev/null -w '%{http_code}\n' https://example.org/birds/avian/api/config.php    # 404
curl -so /dev/null -w '%{http_code}\n' https://example.org/birds/terminal                # 404
```

A blank page with 404s in the browser console for `styles.css` and `apt.js`
almost always means the trailing-slash redirect is missing and you are on
`/birds` rather than `/birds/`.

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

The usual cause is a wrong `REC_CARD`. Check the startup log first: the init
lists every capture device it can see and validates `REC_CARD` against them.

```bash
docker compose logs avianvisitors | grep avian-init
```

```
[avian-init] capture devices visible to the container:
[avian-init]   card 3 [UM02]  -> plughw:3,0  or  plughw:CARD=UM02,DEV=0
[avian-init] WARNING: REC_CARD is 'plughw:1,0' but /dev/snd/pcmC1D0c does not exist,
```

**`arecord: audio open error: No such file or directory`** means exactly that:
`REC_CARD` names a card with no capture node. Two causes, in order of
likelihood.

*Wrong card number.* `arecord -l` on the host gives the truth. Card numbers are
assigned in probe order and change when you re-plug the mic or add another sound
card, so pin it by name: `REC_CARD=plughw:CARD=UM02,DEV=0` rather than
`plughw:3,0`.

*`/dev/snd` not passed through.* Compare host and container:

```bash
ls -l /dev/snd/                                     # host
docker compose exec avianvisitors ls -l /dev/snd/   # container
```

The container needs a `pcmC<card>D0c` node for the card you named. If `/dev/snd`
is empty or absent, the `devices:` entry is missing from `docker-compose.yml`.

If the nodes are there but still unreadable, it is group ownership. The device
nodes belong to the host's `audio` group, and `group_add: [audio]` resolves that
name in the *container's* `/etc/group`. Both Debian and Raspberry Pi OS use gid
29 so they normally agree, but compare the numeric gids if in doubt:

```bash
stat -c '%g' /dev/snd/controlC3                            # host
docker compose exec avianvisitors stat -c '%g' /dev/snd/controlC3
```

If they differ, replace `group_add: [audio]` with the host's numeric gid.

**`arecord: main:830: audio open error: Device or resource busy`**

Something on the host already holds the mic. The container and the host cannot
both capture from it.

**`birdnet_analysis` logs `no more notifications: restarting...` every minute.**

Expected when no audio is arriving. The analyser watches `StreamData` and
restarts itself if nothing lands within `RECORDING_LENGTH * 2 + 30` seconds, on
the assumption the recorder has died. It is upstream's watchdog, not a container
problem: with a working mic a file arrives every 15s and it never fires. If you
see this, fix the audio source and it stops.

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
