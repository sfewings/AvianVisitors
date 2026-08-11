#!/usr/bin/env python3
"""Poll AvianVisitors' recent-detections endpoint once a minute and publish
each new species to MQTT.

Configure by editing the defaults below, or by setting the matching environment
variables - which is how the Docker install drives it, since a container cannot
hand-edit a file baked into an image. Environment wins where both are present.
"""
import json
import os
import time
import urllib.request
import paho.mqtt.client as mqtt  # sudo pip3 install paho-mqtt

BROKER = os.environ.get("MQTT_BROKER", "homeassistant.local")
PORT = int(os.environ.get("MQTT_PORT", "1883"))
USER = os.environ.get("MQTT_USER", "")
PASSWORD = os.environ.get("MQTT_PASSWORD", "")
TOPIC_PREFIX = os.environ.get("MQTT_TOPIC_PREFIX", "birdnet")
PI_URL = os.environ.get(
    "MQTT_PI_URL",
    "http://birdnet.local/avian/api/birdnet-api.php?action=recent&hours=1",
)
POLL_SECONDS = int(os.environ.get("MQTT_POLL_SECONDS", "60"))

# Dedup memory. A dict rather than a set purely for its insertion ordering, so
# the oldest entries can be evicted: this process is expected to run for months
# under a supervisor, and an unbounded set of "<sci>|<last_seen>" keys grows
# without limit for as long as birds keep being detected. The poll window is an
# hour, so a few thousand keys is already far more history than dedup needs.
SEEN_CAP = int(os.environ.get("MQTT_SEEN_CAP", "5000"))
seen_keys: dict[str, None] = {}

def slugify(s: str) -> str:
    return "".join(c.lower() if c.isalnum() else "-" for c in s).strip("-")

def loop(client: mqtt.Client) -> None:
    while True:
        try:
            with urllib.request.urlopen(PI_URL, timeout=10) as r:
                payload = json.loads(r.read())
            for s in payload.get("species", []):
                key = f"{s['sci']}|{s.get('last_seen','')}"
                if key in seen_keys:
                    continue
                seen_keys[key] = None
                while len(seen_keys) > SEEN_CAP:
                    seen_keys.pop(next(iter(seen_keys)))
                topic = f"{TOPIC_PREFIX}/{slugify(s['sci'])}"
                client.publish(topic, json.dumps(s), qos=0, retain=False)
                print(f"published {topic}: {s.get('com')}", flush=True)
        except Exception as e:
            print(f"poll error: {e}", flush=True)
        time.sleep(POLL_SECONDS)

def main() -> None:
    # paho-mqtt 2.x requires CallbackAPIVersion; the constructor below
    # also works on 1.x (the kwarg is just ignored). Pin to VERSION2 so
    # we get the modern callback signatures going forward.
    try:
        client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    except AttributeError:  # paho-mqtt 1.x
        client = mqtt.Client()
    if USER:
        client.username_pw_set(USER, PASSWORD)

    # Retry the initial connect rather than dying on it. paho reconnects by
    # itself once a connection has been established, but a broker that is not
    # up yet raises here - and under a process supervisor a bare raise means
    # exit, restart, raise again, several times a second. Backs off to a minute.
    delay = 5
    while True:
        try:
            client.connect(BROKER, PORT, keepalive=60)
            break
        except Exception as e:
            print(f"connect to {BROKER}:{PORT} failed ({e}); retrying in {delay}s",
                  flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 60)

    print(f"connected to {BROKER}:{PORT}, publishing under {TOPIC_PREFIX}/",
          flush=True)
    client.loop_start()
    loop(client)

if __name__ == "__main__":
    main()
