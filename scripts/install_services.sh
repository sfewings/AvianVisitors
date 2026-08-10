#!/usr/bin/env bash
# This installs the services that have been selected
set -x # Uncomment to enable debugging
trap 'rm -f ${tmpfile}' EXIT
trap 'exit 1' SIGINT SIGHUP
tmpfile=$(mktemp)

config_file=$my_dir/birdnet.conf
export USER=$USER
export HOME=$HOME

export PYTHON_VIRTUAL_ENV="$HOME/BirdNET-Pi/birdnet/bin/python3"

install_depends() {
  apt install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  apt -qqq update && apt -qqy upgrade
  echo "icecast2 icecast2/icecast-setup boolean false" | debconf-set-selections
  apt install --no-install-recommends -qqy caddy sqlite3 php-sqlite3 php-fpm php-curl php-xml php-zip php-mbstring php icecast2 \
    pulseaudio avahi-utils sox libsox-fmt-mp3 alsa-utils ffmpeg \
    wget curl unzip bc \
    python3-pip python3-venv lsof net-tools inotify-tools
}

set_hostname() {
  if [ "$(hostname)" == "raspberrypi" ];then
    hostnamectl set-hostname birdnetpi
    sed -i 's/raspberrypi/birdnetpi/g' /etc/hosts
  fi
}

update_etc_hosts() {
  sed -ie s/'$(hostname).local'/"$(hostname).local ${BIRDNETPI_URL//https:\/\/} ${WEBTERMINAL_URL//https:\/\/} ${BIRDNETLOG_URL//https:\/\/}"/g /etc/hosts
}

install_birdnet_analysis() {
  cat << EOF > $HOME/BirdNET-Pi/templates/birdnet_analysis.service
[Unit]
Description=BirdNET Analysis
[Service]
Restart=always
Type=simple
RestartSec=2
User=${USER}
ExecStart=$PYTHON_VIRTUAL_ENV /usr/local/bin/birdnet_analysis.py
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/birdnet_analysis.service /usr/lib/systemd/system
  systemctl enable birdnet_analysis.service
}

set_login() {
  if ! [ -d /etc/lightdm ];then
    systemctl set-default multi-user.target
    ln -fs /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
    if ! [ -d /etc/systemd/system/getty@tty1.service.d ];then
      mkdir /etc/systemd/system/getty@tty1.service.d
    fi
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM
EOF
  fi
}

install_recording_service() {
  echo "Installing birdnet_recording.service"
  cat << EOF > $HOME/BirdNET-Pi/templates/birdnet_recording.service
[Unit]
Description=BirdNET Recording
[Service]
Restart=always
Type=simple
RestartSec=3
User=${USER}
ExecStart=/usr/local/bin/birdnet_recording.sh
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/birdnet_recording.service /usr/lib/systemd/system
  systemctl enable birdnet_recording.service
}

install_custom_recording_service() {
  echo "Installing custom_recording.service"
  cat << EOF > $HOME/BirdNET-Pi/templates/custom_recording.service
[Unit]
Description=BirdNET Custom Recording
[Service]
Restart=always
Type=simple
RestartSec=3
User=${USER}
ExecStart=/usr/local/bin/custom_recording.sh
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/custom_recording.service /usr/lib/systemd/system
}

install_avahi_aliases() {
  cat << 'EOF' > $HOME/BirdNET-Pi/templates/avahi-alias@.service
[Unit]
Description=Publish %I as alias for %H.local via mdns
After=network.target network-online.target
Requires=network-online.target
[Service]
Restart=always
RestartSec=3
Type=simple
ExecStart=/bin/bash -c "/usr/bin/avahi-publish -a -R %I $(hostname -I |cut -d' ' -f1)"
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/avahi-alias@.service /usr/lib/systemd/system
  systemctl enable avahi-alias@"$(hostname)".local.service
  # symbolic link does not work here, so just copy
  cp -f $HOME/BirdNET-Pi/templates/http.service /etc/avahi/services/
  systemctl restart avahi-daemon.service
}

install_birdnet_stats_service() {
  cat << EOF > $HOME/BirdNET-Pi/templates/birdnet_stats.service
[Unit]
Description=BirdNET Stats
[Service]
Restart=on-failure
RestartSec=5
Type=simple
User=${USER}
ExecStart=$HOME/BirdNET-Pi/birdnet/bin/streamlit run $HOME/BirdNET-Pi/scripts/plotly_streamlit.py --browser.gatherUsageStats false --server.address localhost --server.baseUrlPath "/stats"

[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/birdnet_stats.service /usr/lib/systemd/system
  systemctl enable birdnet_stats.service
}

install_spectrogram_service() {
  cat << EOF > $HOME/BirdNET-Pi/templates/spectrogram_viewer.service
[Unit]
Description=BirdNET-Pi Spectrogram Viewer
[Service]
Restart=always
RestartSec=10
Type=simple
User=${USER}
ExecStart=/usr/local/bin/spectrogram.sh
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/spectrogram_viewer.service /usr/lib/systemd/system
  systemctl enable spectrogram_viewer.service
}

install_chart_viewer_service() {
  echo "Installing the chart_viewer.service"
  cat << EOF > $HOME/BirdNET-Pi/templates/chart_viewer.service
[Unit]
Description=BirdNET-Pi Chart Viewer Service
[Service]
Restart=always
RestartSec=120
Type=simple
User=$USER
ExecStart=$PYTHON_VIRTUAL_ENV /usr/local/bin/daily_plot.py --daemon --sleep 2
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/chart_viewer.service /usr/lib/systemd/system
  systemctl enable chart_viewer.service
}

install_gotty_logs() {
  sudo -u ${USER} ln -sf $my_dir/templates/gotty \
    ${HOME}/.gotty
  sudo -u ${USER} ln -sf $my_dir/templates/bashrc \
    ${HOME}/.bashrc
  cat << EOF > $HOME/BirdNET-Pi/templates/birdnet_log.service
[Unit]
Description=BirdNET Analysis Log
[Service]
Restart=on-failure
RestartSec=3
Type=simple
User=${USER}
Environment=TERM=xterm-256color
ExecStart=/usr/local/bin/gotty --address localhost -p 8080 --path log --title-format "BirdNET-Pi Log" birdnet_log.sh
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/birdnet_log.service /usr/lib/systemd/system
  systemctl enable birdnet_log.service
  cat << EOF > $HOME/BirdNET-Pi/templates/web_terminal.service
[Unit]
Description=BirdNET-Pi Web Terminal
[Service]
Restart=on-failure
RestartSec=3
Type=simple
User=${USER}
Environment=TERM=xterm-256color
ExecStart=/usr/local/bin/gotty --address localhost -w -p 8888 --path terminal --title-format "BirdNET-Pi Terminal" bash -c 'read -p "Login: " username && [[ "\$username" =~ ^[-_.a-z0-9]{1,30}$ ]] && su --pty -l \$username'
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/web_terminal.service /usr/lib/systemd/system
  systemctl enable web_terminal.service
}

install_livestream_service() {
  cat << EOF > $HOME/BirdNET-Pi/templates/livestream.service
[Unit]
Description=BirdNET-Pi Live Stream
After=network-online.target
Requires=network-online.target
[Service]
Restart=always
Type=simple
RestartSec=3
User=${USER}
ExecStart=/usr/local/bin/livestream.sh
[Install]
WantedBy=multi-user.target
EOF
  ln -sf $HOME/BirdNET-Pi/templates/livestream.service /usr/lib/systemd/system
  systemctl enable livestream.service
}

install_cleanup_cron() {
  sed "s/\$USER/$USER/g" $my_dir/templates/cleanup.cron >> /etc/crontab
}

install_weekly_cron() {
  sed "s/\$USER/$USER/g" $my_dir/templates/weekly_report.cron >> /etc/crontab
}

install_automatic_update_cron() {
  sed "s/\$USER/$USER/g" $my_dir/templates/automatic_update.cron >> /etc/crontab
}

increase_caddy_timeout() {
  mkdir /etc/systemd/system/caddy.service.d
  cat << EOF > /etc/systemd/system/caddy.service.d/override.conf
[Service]
TimeoutSec=300s
EOF
  systemctl daemon-reload
}

install_services() {
  set_hostname
  update_etc_hosts
  set_login
  install_tmp_mount

  install_depends
  install_scripts
  install_Caddyfile
  install_avahi_aliases
  install_birdnet_analysis
  install_birdnet_stats_service
  install_recording_service
  install_custom_recording_service # But does not enable
  install_spectrogram_service
  install_chart_viewer_service
  install_gotty_logs
  install_phpsysinfo
  install_livestream_service
  install_birdnet_mount
  install_cleanup_cron
  install_weekly_cron
  install_automatic_update_cron
  increase_caddy_timeout

  create_necessary_dirs
  fix_permissions
  generate_BirdDB
  configure_caddy_php
  config_icecast
  USER=$USER HOME=$HOME ${my_dir}/scripts/createdb.sh
}

if [ -f ${config_file} ];then
  source ${config_file}
  source install_helpers.sh
  # Steps shared with the Docker image build. Keeps the two install paths from
  # drifting - see scripts/install_lib.sh.
  source install_lib.sh
  install_services
  chown_things
else
  echo "Unable to find a configuration file. Please make sure that $config_file exists."
fi
