#!/usr/bin/env bash
#
# Recover the ASUS ProArt PX13 internal-speaker audio by resetting the AMD
# ACP / SoundWire controller, then refreshing PipeWire/WirePlumber.
#
# Used by px13-audio-resume.service (runs after resume from
# suspend/hibernate). Adapted from
# https://github.com/brainchillz/asus-proart-px13-linux-speaker-fix
# (PCI address auto-detected instead of hardcoded).
#
# Why a full PCI reset (and not just a slave rebind):
#
#   On s2idle resume the whole AMD ACP/SoundWire controller fails to come
#   back - the entire "amd-soundwire" ALSA card (card 1) DISAPPEARS, not
#   just the tas2783 amps. Trying to unbind an individual tas2783 SoundWire
#   slave at that point BLOCKS for ~90s (the bus controller is dead), which
#   is exactly what used to hang the resume hook and leave audio on "Dummy
#   Output".
#
#   Unbinding/re-binding the parent ACP PCI device (AMD 1022:15e2, driver
#   snd_pci_ps; address auto-detected below) tears the whole stack down and re-probes it from scratch -
#   the two SoundWire managers, both tas2783 smart amps (re-downloading
#   their 1714-1-8/1714-1-B calibration firmware) and the rt721 jack codec -
#   recreating card 1 cleanly, the same way a cold boot does. This also
#   covers the intermittent tas2783 "FW download failed: -110" SDW bus
#   timeout that can hit slave 01:b at boot.
#
# See the project README for full background.

set -uo pipefail

PCI_DRV="/sys/bus/pci/drivers/snd_pci_ps"
CARD_MATCH="amd-soundwire"
# AMD Audio Coprocessor (ACP) PCI vendor:device id
ACP_VENDOR="0x1022"
ACP_DEVICE="0x15e2"

log() { echo "px13-audio-fix: $*"; }

# --- Locate the ACP PCI device -----------------------------------------------
# The PCI bus number differs between units/firmware revisions (seen as both
# 0000:c3:00.5 and 0000:c4:00.5), so don't hardcode it. Set PX13_ACP_PCI_DEV
# to override. Otherwise look the device up by vendor:device id; this works
# even when it is currently unbound (e.g. after a failed resume).
find_acp_dev() {
  local d
  if [ -n "${PX13_ACP_PCI_DEV:-}" ]; then
    echo "$PX13_ACP_PCI_DEV"
    return
  fi
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "$ACP_VENDOR" ] || continue
    [ "$(cat "$d/device" 2>/dev/null)" = "$ACP_DEVICE" ] || continue
    basename "$d"
    return
  done
}

PCI_DEV="$(find_acp_dev)"
if ! [[ "$PCI_DEV" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] \
   || [ ! -e "/sys/bus/pci/devices/$PCI_DEV" ]; then
  log "AMD ACP PCI device not found (got '${PCI_DEV}') - cannot reset"
  PCI_DEV=""
else
  log "using ACP PCI device $PCI_DEV"
fi

# --- Reset the ACP PCI device ------------------------------------------------
# The sysfs writes are wrapped in `timeout` because the unbind can block
# indefinitely if attempted while the ACP/SoundWire bus is in its broken
# just-resumed state (this must run AFTER resume+thaw - see
# px13-audio-resume.service - not from inside the systemd-sleep hook).
pci_write() { timeout 30 sh -c "echo '$1' > '$2'" 2>/dev/null; }

if [ -z "$PCI_DEV" ]; then
  : # already logged above
elif [ ! -d "$PCI_DRV" ]; then
  log "snd_pci_ps driver not present, cannot reset - skipping"
elif [ ! -e "$PCI_DRV/$PCI_DEV" ]; then
  log "PCI $PCI_DEV not currently bound to snd_pci_ps - attempting bind only"
  pci_write "$PCI_DEV" "$PCI_DRV/bind" || log "bind failed/timed out"
else
  log "unbinding PCI $PCI_DEV"
  pci_write "$PCI_DEV" "$PCI_DRV/unbind" || log "unbind failed/timed out"
  sleep 2
  log "binding PCI $PCI_DEV"
  pci_write "$PCI_DEV" "$PCI_DRV/bind" || log "bind failed/timed out"
fi

# --- Wait for the amd-soundwire card to reappear -----------------------------
# Firmware download for the tas2783 amps is asynchronous after the bind.
for _ in $(seq 1 40); do
  if grep -q "$CARD_MATCH" /proc/asound/cards 2>/dev/null; then
    log "amd-soundwire card is present"
    break
  fi
  sleep 0.25
done
grep -q "$CARD_MATCH" /proc/asound/cards 2>/dev/null \
  || log "WARNING: amd-soundwire card did not reappear"

# Let the tas2783 firmware download / amp init settle before touching PipeWire.
sleep 2

# --- Refresh PipeWire/WirePlumber for each logged-in user --------------------
# Restart it so it cleanly re-enumerates the recreated card.
#
# Safety net: if this ever runs while user.slice is still FROZEN (as it did
# from the original project's systemd-sleep hook), a `systemctl --user` call
# would block until the session thaws. So we skip the restart for any frozen
# session - WirePlumber's udev monitor
# delivers the card remove/add events on its own once the session thaws, and
# re-creates the "Speaker" sink without any restart.
for uid in $(loginctl list-users --no-legend | awk '{print $1}'); do
  runtime_dir="/run/user/$uid"
  user_name="$(id -nu "$uid" 2>/dev/null)" || continue
  [ -d "$runtime_dir" ] || continue

  events="/sys/fs/cgroup/user.slice/user-${uid}.slice/cgroup.events"
  if [ -r "$events" ] && grep -q "^frozen 1$" "$events" 2>/dev/null; then
    log "uid $uid ($user_name) session frozen - skipping pipewire restart" \
        "(udev will re-enumerate on thaw)"
    continue
  fi

  log "restarting pipewire for uid $uid ($user_name)"
  sudo -u "$user_name" XDG_RUNTIME_DIR="$runtime_dir" \
    systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null \
    || log "pipewire restart for uid $uid failed"
done
