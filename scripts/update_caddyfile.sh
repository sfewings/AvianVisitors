#!/usr/bin/env bash
source /etc/birdnet/birdnet.conf
my_dir=$HOME/BirdNET-Pi/scripts
set -x

# Find the active PHP-FPM Unix socket. The path is version-specific on
# modern Raspberry Pi OS (e.g. /run/php/php8.2-fpm.sock); the generic
# /run/php/php-fpm.sock only exists if a compat shim is installed, so
# hardcoding it breaks Caddy's php_fastcgi handler on stock Bookworm.
FPM_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1)
FPM_SOCK=${FPM_SOCK:-/run/php/php-fpm.sock}

[ -d /etc/caddy ] || mkdir /etc/caddy
if [ -f /etc/caddy/Caddyfile ];then
  cp /etc/caddy/Caddyfile{,.original}
fi

# Everything common to every site goes in a Caddy snippet, imported below.
# Previously this body was duplicated between the with-password and
# without-password branches; with a second site on its own port that would have
# meant four copies of the same twenty lines.
AUTH_BLOCK=
if ! [ -z ${CADDY_PWD} ];then
  HASHWORD=$(caddy hash-password --plaintext ${CADDY_PWD})
  AUTH_BLOCK=$(cat << EOF
  basicauth /views.php?view=File* {
    birdnet ${HASHWORD}
  }
  basicauth /Processed* {
    birdnet ${HASHWORD}
  }
  basicauth /scripts* {
    birdnet ${HASHWORD}
  }
  basicauth /stream {
    birdnet ${HASHWORD}
  }
  basicauth /phpsysinfo* {
    birdnet ${HASHWORD}
  }
  basicauth /terminal* {
    birdnet ${HASHWORD}
  }
EOF
)
fi

# STOCK_UI_PORT optionally publishes the original BirdNET-Pi UI on a port of its
# own, so the collage and the stock interface are both reachable at "/" instead
# of the stock one hiding behind /index.php. Empty (the default) means one site
# only, exactly as before.
STOCK_UI_BLOCK=
if [ -n "${STOCK_UI_PORT:-}" ];then
  STOCK_UI_BLOCK=$(cat << EOF

# The stock BirdNET-Pi UI, on its own port. Same web root and the same proxied
# services; the only difference is that php_fastcgi keeps Caddy's default
# try_files, which prefers index.php, so "/" lands on the stock interface rather
# than the collage's index.html.
http://:${STOCK_UI_PORT} {
  import birdnet_common
  php_fastcgi unix/${FPM_SOCK}
}
EOF
)
fi

cat << EOF > /etc/caddy/Caddyfile
(birdnet_common) {
  root * ${EXTRACTED}
  # The HTML shell must always revalidate so UI deploys and re-rendered
  # illustrations show up on the next load; versioned assets (?v=) keep
  # caching normally.
  @shell path / /index.html
  header @shell Cache-Control "no-cache"
  file_server browse
  handle /By_Date/* {
    file_server browse
  }
  handle /Charts/* {
    file_server browse
  }
${AUTH_BLOCK}
  reverse_proxy /stream localhost:8000
  reverse_proxy /log* localhost:8080
  reverse_proxy /stats* localhost:8501
  reverse_proxy /terminal* localhost:8888
}

http:// ${BIRDNETPI_URL} {
  import birdnet_common
  # AvianVisitors overlay drops an index.html alongside BirdNET-Pi's
  # index.php. The default try_files for php_fastcgi prefers index.php
  # over index.html, so override it - this is a no-op on stock installs
  # since EXTRACTED has no index.html there.
  php_fastcgi unix/${FPM_SOCK} {
    try_files {path} {path}/index.html {path}/index.php index.php
  }
}
${STOCK_UI_BLOCK}
EOF

sudo caddy fmt --overwrite /etc/caddy/Caddyfile
# Fail loudly on a Caddyfile caddy can't parse rather than reloading a broken
# config and reporting success.
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || {
  echo "generated Caddyfile failed validation; not reloading caddy" >&2
  exit 1
}
# reload-or-restart so this also works at install time, when caddy may not be
# running yet (a plain reload would fail there); tolerate a not-yet-ready unit.
sudo systemctl reload-or-restart caddy 2>/dev/null || true
