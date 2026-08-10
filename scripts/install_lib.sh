#!/usr/bin/env bash
# Portable install steps shared by the bare-metal installer and the Docker
# image build.
#
# Everything in here must work in both places, which means: no hostnamectl, no
# avahi, no apt, no systemd unit files, no host hardware assumptions. Anything
# host-specific stays in install_services.sh; anything container-specific stays
# in docker/container_install.sh.
#
# The container gets a systemctl shim on PATH (docker/shims/systemctl) that
# no-ops enable/disable and maps start/stop/restart onto s6, so the systemctl
# calls below are safe in both environments.
#
# This file must only define functions. Sourcing it has no side effects.
#
# Expected in the environment before calling any of these:
#   my_dir  - the BirdNET-Pi checkout (e.g. /home/birdnet/BirdNET-Pi)
#   HOME    - the BirdNET user's home
#   USER    - the BirdNET user
# plus the variables from birdnet.conf (EXTRACTED, PROCESSED, RECS_DIR, ...).

install_scripts() {
  ln -sf "${my_dir}"/scripts/* /usr/local/bin/
}

create_necessary_dirs() {
  echo "Creating necessary directories"
  [ -d ${EXTRACTED} ] || sudo -u ${USER} mkdir -p ${EXTRACTED}
  [ -d ${EXTRACTED}/By_Date ] || sudo -u ${USER} mkdir -p ${EXTRACTED}/By_Date
  [ -d ${EXTRACTED}/Charts ] || sudo -u ${USER} mkdir -p ${EXTRACTED}/Charts
  [ -d ${PROCESSED} ] || sudo -u ${USER} mkdir -p ${PROCESSED}
  [ -d $RECS_DIR/StreamData ] || sudo -u ${USER} mkdir -p $RECS_DIR/StreamData
  [ -L ${EXTRACTED}/spectrogram.png ] || sudo -u ${USER} ln -sf ${RECS_DIR}/StreamData/spectrogram.png ${EXTRACTED}/spectrogram.png

  sudo -u ${USER} ln -fs $my_dir/exclude_species_list.txt $my_dir/scripts
  sudo -u ${USER} ln -fs $my_dir/confirmed_species_list.txt $my_dir/scripts
  sudo -u ${USER} ln -fs $my_dir/include_species_list.txt $my_dir/scripts
  sudo -u ${USER} ln -fs $my_dir/whitelist_species_list.txt $my_dir/scripts
  sudo -u ${USER} ln -fs $my_dir/homepage/* ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/model/labels.txt ${my_dir}/scripts
  sudo -u ${USER} ln -fs $my_dir/scripts ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/scripts/play.php ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/scripts/spectrogram.php ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/scripts/overview.php ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/scripts/stats.php ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/scripts/todays_detections.php ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/scripts/history.php ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/weekly_report.php ${EXTRACTED}
  if ! source "$my_dir/scripts/link_webroot.sh"; then
    echo "Could not load the AvianVisitors webroot helper" >&2
    exit 1
  fi
  if ! link_avian_visitors_webroot "$my_dir" "${EXTRACTED}" "${USER}"; then
    echo "Could not create the AvianVisitors webroot links" >&2
    exit 1
  fi
  sudo -u ${USER} ln -fs ${HOME}/phpsysinfo ${EXTRACTED}
  sudo -u ${USER} ln -fs $my_dir/templates/phpsysinfo.ini ${HOME}/phpsysinfo/
  sudo -u ${USER} ln -fs $my_dir/templates/green_bootstrap.css ${HOME}/phpsysinfo/templates/
  sudo -u ${USER} ln -fs $my_dir/templates/index_bootstrap.html ${HOME}/phpsysinfo/templates/html
  sudo -u ${USER} ln -sf $my_dir/model/labels_nm/labels_en.txt $my_dir/model/labels_flickr.txt
}

# Recursive, and therefore slow once ${RECS_DIR} has a few thousand extractions
# in it. Split out of create_necessary_dirs so the container can refresh the
# web-root symlinks on every boot (they point into the image layer and go stale
# after an image update) without paying for a full tree walk each time. The
# bare-metal installer calls both, back to back, exactly as before.
fix_permissions() {
  chmod -R g+rw $my_dir
  chmod -R g+rw ${RECS_DIR}
}

generate_BirdDB() {
  echo "Generating BirdDB.txt"
  if ! [ -f $my_dir/BirdDB.txt ];then
    sudo -u ${USER} touch $my_dir/BirdDB.txt
    echo "Date;Time;Sci_Name;Com_Name;Confidence;Lat;Lon;Cutoff;Week;Sens;Overlap" | sudo -u ${USER} tee -a $my_dir/BirdDB.txt
  elif ! grep Date $my_dir/BirdDB.txt;then
    sudo -u ${USER} sed -i '1 i\Date;Time;Sci_Name;Com_Name;Confidence;Lat;Lon;Cutoff;Week;Sens;Overlap' $my_dir/BirdDB.txt
  fi
  chown $USER:$USER ${my_dir}/BirdDB.txt && chmod g+rw ${my_dir}/BirdDB.txt
}

install_Caddyfile() {
  [ -d /etc/caddy ] || mkdir /etc/caddy
  if [ -f /etc/caddy/Caddyfile ];then
    cp /etc/caddy/Caddyfile{,.original}
  fi
  if ! [ -z ${CADDY_PWD} ];then
  HASHWORD=$(caddy hash-password --plaintext ${CADDY_PWD})
  cat << EOF > /etc/caddy/Caddyfile
http:// ${BIRDNETPI_URL} {
  root * ${EXTRACTED}
  file_server browse
  handle /By_Date/* {
    file_server browse
  }
  handle /Charts/* {
    file_server browse
  }
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
  reverse_proxy /stream localhost:8000
  php_fastcgi unix//run/php/php-fpm.sock
  reverse_proxy /log* localhost:8080
  reverse_proxy /stats* localhost:8501
  reverse_proxy /terminal* localhost:8888
}
EOF
  else
    cat << EOF > /etc/caddy/Caddyfile
http:// ${BIRDNETPI_URL} {
  root * ${EXTRACTED}
  file_server browse
  handle /By_Date/* {
    file_server browse
  }
  handle /Charts/* {
    file_server browse
  }
  reverse_proxy /stream localhost:8000
  php_fastcgi unix//run/php/php-fpm.sock
  reverse_proxy /log* localhost:8080
  reverse_proxy /stats* localhost:8501
  reverse_proxy /terminal* localhost:8888
}
EOF
  fi

  systemctl enable caddy
  usermod -aG $USER caddy
  usermod -aG video caddy
  chmod g+r+x $HOME

  # Serve the AvianVisitors collage at / rather than the stock BirdNET-Pi UI.
  # The Caddyfile written above is the stock one (hardcoded php-fpm.sock, no
  # index.html try_files override); re-apply both through update_caddyfile.sh,
  # the single source of truth, so / serves index.html not index.php. Run it
  # last so it wins.
  "$my_dir/scripts/update_caddyfile.sh"
}

configure_caddy_php() {
  echo "Configuring PHP for Caddy"
  sed -i 's/www-data/caddy/g' /etc/php/*/fpm/pool.d/www.conf
  systemctl restart php\*-fpm.service
  echo "Adding Caddy sudoers rule"
  cat << EOF > /etc/sudoers.d/010_caddy-nopasswd
caddy ALL=(ALL) NOPASSWD: ALL
EOF
  chmod 0440 /etc/sudoers.d/010_caddy-nopasswd
  # AvianVisitors admin overlay needs to restart whitelisted units and
  # tail their journal. The 010 rule above already covers everything via
  # NOPASSWD: ALL - this 020 rule pins the exact commands we depend on
  # so the admin overlay stays working even if a future upstream change
  # tightens 010. See SECURITY.md for the longer story.
  if [ -d $my_dir/avian ]; then
    echo "Adding AvianVisitors admin allowlist"
    cat << EOF > /etc/sudoers.d/020_avian-admin
caddy ALL=(root) NOPASSWD: \\
    /bin/systemctl restart birdnet_recording, \\
    /bin/systemctl restart birdnet_analysis, \\
    /bin/systemctl restart birdnet_log, \\
    /bin/systemctl restart birdnet_stats, \\
    /bin/systemctl restart spectrogram_viewer, \\
    /bin/systemctl restart livestream, \\
    /bin/systemctl restart icecast2, \\
    /bin/systemctl restart caddy, \\
    /bin/journalctl -u birdnet_recording *, \\
    /bin/journalctl -u birdnet_analysis *, \\
    /bin/journalctl -u birdnet_log *, \\
    /bin/journalctl -u birdnet_stats *, \\
    /bin/journalctl -u spectrogram_viewer *, \\
    /bin/journalctl -u livestream *, \\
    /bin/journalctl -u icecast2 *, \\
    /bin/journalctl -u caddy *
EOF
    chmod 0440 /etc/sudoers.d/020_avian-admin
    visudo -c -f /etc/sudoers.d/020_avian-admin >/dev/null
  fi
}

install_phpsysinfo() {
  sudo -u ${USER} git clone https://github.com/phpsysinfo/phpsysinfo.git \
    ${HOME}/phpsysinfo
}

config_icecast() {
  if [ -f /etc/icecast2/icecast.xml ];then
    cp /etc/icecast2/icecast.xml{,.prebirdnetpi}
  fi
  sed -i 's/>admin</>birdnet</g' /etc/icecast2/icecast.xml
  passwords=("source-" "relay-" "admin-" "master-" "")
  for i in "${passwords[@]}";do
  sed -i "s/<${i}password>.*<\/${i}password>/<${i}password>${ICE_PWD}<\/${i}password>/g" /etc/icecast2/icecast.xml
  done
  sed -i 's|<!-- <bind-address>.*|<bind-address>127.0.0.1</bind-address>|;s|<!-- <shoutcast-mount>.*|<shoutcast-mount>/stream</shoutcast-mount>|' /etc/icecast2/icecast.xml

  systemctl enable icecast2.service
}

chown_things() {
  chown -R $USER:$USER $HOME/Bird*
}
