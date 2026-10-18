#!/usr/bin/env bash
#
# OPTIONAL - only if the speakers stop working after suspend/resume.
#
# Installs a post-resume systemd service that resets the AMD ACP/SoundWire
# controller (PCI unbind/bind, address auto-detected) and restarts PipeWire.
# The original project needed this because the whole amd-soundwire card
# disappeared after s2idle resume on their setup. It has not been required
# (or verified) on the setup this repo was tested on.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo install -m 755 "$SCRIPT_DIR/px13-audio-fix.sh" /usr/local/sbin/px13-audio-fix.sh
sudo install -m 644 "$SCRIPT_DIR/px13-audio-resume.service" /etc/systemd/system/px13-audio-resume.service
sudo systemctl daemon-reload
sudo systemctl enable px13-audio-resume.service

echo "==> Installed. Suspend and resume, then check:"
echo "    journalctl -b 0 -u px13-audio-resume.service"
echo "    wpctl status"
echo "Remove again with ../uninstall.sh (also removes the firmware) or:"
echo "    sudo systemctl disable px13-audio-resume.service"
