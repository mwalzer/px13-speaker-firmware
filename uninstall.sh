#!/usr/bin/env bash
#
# Remove everything install.sh and optional/install-resume-fix.sh installed.

set -uo pipefail

echo "==> Removing TAS2783 calibration firmware"
sudo rm -f /lib/firmware/1714-1-8.bin /lib/firmware/1714-1-B.bin

if [ -e /etc/systemd/system/px13-audio-resume.service ]; then
  echo "==> Removing optional resume fix"
  sudo systemctl disable px13-audio-resume.service
  sudo rm -f /etc/systemd/system/px13-audio-resume.service /usr/local/sbin/px13-audio-fix.sh
  sudo systemctl daemon-reload
fi

echo "==> Done. Reboot to unload the firmware."
