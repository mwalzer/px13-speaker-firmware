#!/usr/bin/env bash
#
# Install the TAS2783 calibration firmware for the ASUS ProArt PX13 (HN7306)
# internal speakers. This is the only change needed on a current distro
# (tested: Ubuntu 26.04.1, kernel 7.0.0-38, alsa-ucm-conf 1.2.15.3).
#
# Usage:
#   ./install.sh            install firmware/1714-1-{8,B}.bin into /lib/firmware
#   ./install.sh --force    install even if the checksums differ from the
#                           known V6.3.1.15_47519 blobs
#
# Extract the firmware first: python3 firmware/extract-firmware.py SmartAMP_TI_*.exe

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$SCRIPT_DIR/firmware"
DEST=/lib/firmware
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# SHA-256 of the blobs in ASUS "TI SmartAMP" driver V6.3.1.15_47519
declare -A KNOWN_SHA256=(
  [1714-1-8.bin]=9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca
  [1714-1-B.bin]=a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1
)

for fw in "${!KNOWN_SHA256[@]}"; do
  if [ ! -f "$FW_DIR/$fw" ]; then
    echo "ERROR: $FW_DIR/$fw missing." >&2
    echo "       Run: python3 firmware/extract-firmware.py SmartAMP_TI_*.exe" >&2
    exit 1
  fi
  sum="$(sha256sum "$FW_DIR/$fw" | cut -d' ' -f1)"
  if [ "$sum" != "${KNOWN_SHA256[$fw]}" ]; then
    echo "WARNING: $fw checksum differs from the known V6.3.1.15_47519 blob." >&2
    if [ "$FORCE" -ne 1 ]; then
      echo "         A newer ASUS package may ship different (valid) calibration" >&2
      echo "         data. Re-run with --force to install it anyway." >&2
      exit 1
    fi
  fi
done

UCM=/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
if [ ! -f "$UCM" ]; then
  echo "WARNING: $UCM not found - your alsa-ucm-conf is probably too old to"
  echo "         expose the speaker (needs >= 1.2.15). See README, 'Older distros'."
fi

echo "==> Installing TAS2783 calibration firmware into $DEST"
for fw in "${!KNOWN_SHA256[@]}"; do
  sudo install -m 644 "$FW_DIR/$fw" "$DEST/$fw"
done

echo
echo "==> Done. Reboot, then check:"
echo "    journalctl -k -b 0 | grep -i 'tas2783\|1714-1'   (no firmware errors)"
echo "    wpctl status                                    ('Audio Coprocessor Speaker')"
echo "    speaker-test -D pipewire -c 2 -t sine -f 440 -l 1"
