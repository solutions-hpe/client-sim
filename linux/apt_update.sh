#!/bin/bash
version=.03
echo apt update Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
#------------------------------------------------------------
sudo apt update
sudo dpkg --configure -a
echo Running system updates | tee -a /tmp/client-sim.log
sudo dkpg --configure -a
sudo DEBIAN_FRONTEND=noninteractive apt update
# --- Kernel / build support ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  linux-headers-$(uname -r) \
  dkms
# --- Core system utilities ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  bash \
  coreutils \
  util-linux \
  procps \
  sudo \
  ca-certificates \
  rsyslog \
  sysstat
# --- Networking (Raspberry Pi OS–compatible stack) ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  network-manager \
  wpasupplicant \
  systemd-resolved \
  net-tools \
  dnsutils \
  iw \
  wireless-tools \
  rfkill \
  iperf3
# --- Remove conflicting network stacks ---
sudo DEBIAN_FRONTEND=noninteractive apt purge -y \
  dhcpcd5 \
  ifupdown \
  connman \
  netplan.io
# --- Admin / utility tools (from your list) ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  git \
  wget \
  smbclient \
  qemu-guest-agent
# --- Python (Pi‑compatible expectations) ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  python3 \
  python3-pip \
  python3-venv \
  python-is-python3 \
  python3-smbus
# --- Hardware / I2C ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  i2c-tools
# --- Optional browser (remove if truly headless) ---
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
  firefox-esr
# --- Cleanup ---
sudo DEBIAN_FRONTEND=noninteractive apt autoremove -y --purge
sudo DEBIAN_FRONTEND=noninteractive apt autoclean
sudo DEBIAN_FRONTEND=noninteractive apt install -y python3-smbus
sudo DEBIAN_FRONTEND=noninteractive apt autoremove -y
