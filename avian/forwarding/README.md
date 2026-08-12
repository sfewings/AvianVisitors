# Forwarding

Default install hosts the collage at `http://birdnet.local/` on your LAN, no auth. The recipes below are independent. Pick what you need.

---

## 1. Cloudflare Tunnel

Public HTTPS URL, no port forwarding. Needs a free Cloudflare account.

```bash
sudo apt install -y lsb-release
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared

cloudflared tunnel login
cloudflared tunnel create birds
cloudflared tunnel route dns birds birds.your-domain.com

sudo cp ~/BirdNET-Pi/avian/forwarding/cloudflared.yml /etc/cloudflared/config.yml
# Edit /etc/cloudflared/config.yml: set `tunnel:` to your UUID
sudo cloudflared service install
sudo systemctl restart cloudflared
```

Add a password gate via Cloudflare Access (free for up to 50 users) or via Caddy basic_auth ([`caddy-auth.caddy`](caddy-auth.caddy)).

---

## 2. Home Assistant sensor

Add to `configuration.yaml`:

```yaml
rest:
  - resource: http://birdnet.local/avian/api/birdnet-api.php?action=recent&hours=1
    scan_interval: 60
    sensor:
      - name: "Latest Bird"
        value_template: "{{ value_json.species[0].com if value_json.species else 'none' }}"
        json_attributes_path: "$.species[0]"
        json_attributes:
          - sci
          - n
          - last_seen
          - best_conf
```

---

## 3. MQTT bridge

```bash
sudo pip3 install paho-mqtt --break-system-packages
cp ~/BirdNET-Pi/avian/forwarding/mqtt-bridge.py ~/avian-mqtt.py
# Edit ~/avian-mqtt.py: broker host, topic prefix, credentials
sudo cp ~/BirdNET-Pi/avian/forwarding/avian-mqtt.service /etc/systemd/system/
# Edit /etc/systemd/system/avian-mqtt.service: set User= to your username
sudo systemctl daemon-reload
sudo systemctl enable --now avian-mqtt
```

Polls `birdnet-api.php?action=recent&hours=1` every 60 seconds. Publishes new species under `birdnet/<slug>` as JSON. Dedup is in-memory; restarts re-emit recent detections.

### End-of-day email table (Node-RED)

[`nodered-daily-email.json`](nodered-daily-email.json) is an importable flow that
appends an HTML table of the day's birds to a daily email file at midnight:
common name, detection count, last seen, and the scientific name deep-linked into
the collage. Import via the Node-RED menu, then edit the site URL, the API host
and the output path in the function and file nodes.

It contains two alternatives. **Enable one**, or you get two tables.

*Flow A, recommended.* One HTTP GET to
`birdnet-api.php?action=recent&hours=24` at midnight. The counts come straight
from `birds.db`, so they are exact, and there is no state to lose.

*Flow B, MQTT.* Tracks the `birdnet/#` stream in flow context. Since the bridge
polls with `hours=24`, each message already carries a daily count, so this keeps
the newest `n` per species rather than counting messages, which would only be a
lower bound (the bridge publishes once per poll cycle in which `last_seen`
advanced, however many calls happened inside it).

Two caveats. That count is a **rolling** 24h window anchored at the species' last
sighting, not the calendar day, so a bird last heard at 06:00 carries a count
reaching back into the previous day; Flow A has the same window but asks once, at
the moment it matters, so it does not skew per species. And the tally is lost if
Node-RED restarts mid-day without persistent context.

Use Flow B if Node-RED cannot reach the station's HTTP API. Otherwise prefer A.

If you change `MQTT_PI_URL` back to a shorter window, Flow B's counts shrink to
match it, whereas Flow A is unaffected.

Every constant in the script can also be set from the environment (`MQTT_BROKER`, `MQTT_PORT`, `MQTT_USER`, `MQTT_PASSWORD`, `MQTT_TOPIC_PREFIX`, `MQTT_PI_URL`, `MQTT_POLL_SECONDS`), which is how the Docker install drives it. Environment wins over the in-file defaults. See [`docs/docker.md`](../../docs/docker.md) for the container setup.
