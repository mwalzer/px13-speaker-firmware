# ASUS ProArt PX13 (HN7306) — internal speaker firmware for Linux

On a current Linux distro, the **only** thing the ASUS ProArt PX13 (HN7306,
Strix Halo) needs for working internal speakers is the per-laptop **TI
TAS2783 calibration firmware**. This repo extracts it from ASUS's Windows
driver (with nothing but Python's standard library) and installs it.

**Symptom this fixes:** internal speakers silent, PipeWire shows only
"Dummy Output", and the kernel log shows:

```
slave-tas2783 ...: Direct firmware load for 1714-1-8.bin failed with error -2
slave-tas2783 ...: error playback without fw download
```

## Tested on

| | |
|---|---|
| Laptop | ASUS ProArt PX13 HN7306EAC (PCI subsystem `1043:1714`) |
| OS | Ubuntu 26.04.1 LTS |
| Kernel | 7.0.0-38-generic |
| alsa-ucm-conf | 1.2.15.3-1ubuntu1.7 |
| PipeWire / WirePlumber | 1.6.2 / 0.5.13 |

## Usage

1. **Download** the ASUS "TI SmartAMP" driver from the PX13 (HN7306) support
   page → Driver & Tools → Audio. Tested with
   `SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe`
   (direct link, may expire:
   `https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/Audio/47519/SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe?model=HN7306EAC`).
   Putting it in `firmware/` is fine; `.gitignore` keeps it out of git.

2. **Extract** the two calibration blobs:

   ```bash
   python3 firmware/extract-firmware.py firmware/SmartAMP_TI_*.exe
   ```

   This writes `firmware/1714-1-8.bin` and `firmware/1714-1-B.bin` and prints
   their SHA-256. Nothing from the installer is executed: the EXE carries its
   payload as a plain 7z archive, which the script reads and decompresses with
   the stdlib `lzma` module. (`--list` shows the archive contents; 7-Zip works
   too: `7z x SmartAMP_TI_*.exe 'Firmwares/1714-1-*.bin'`, then drop the `0x`
   from the names.)

3. **Install** (checks the SHA-256 first, then copies to `/lib/firmware`):

   ```bash
   ./install.sh
   ```

4. **Reboot**, then verify:

   ```bash
   journalctl -k -b 0 | grep -i 'tas2783\|1714-1'   # no firmware errors
   wpctl status                                    # "Audio Coprocessor Speaker"
   speaker-test -D pipewire -c 2 -t sine -f 440 -l 1
   ```

Undo with `./uninstall.sh`.

Expected SHA-256 for the V6.3.1.15_47519 package (both files 40746 bytes):

```
9a105de50978fc3250062d66bea6b77f3aaabaf85280739be28ff1ed3ae535ca  1714-1-8.bin
a975dc7e2340cb5c97259d5e8c3d7e447b5a0af1a91528c058c9fda0adeb74c1  1714-1-B.bin
```

A newer ASUS package may ship different calibration data; `./install.sh
--force` installs it anyway.

## Relation to brainchillz/asus-proart-px13-linux-speaker-fix

This repo is distilled from
[brainchillz/asus-proart-px13-linux-speaker-fix](https://github.com/brainchillz/asus-proart-px13-linux-speaker-fix),
which fixes three problems. On the setup above, only the first one still
exists:

| Original fix | Needed here? | Why |
|---|---|---|
| TAS2783 calibration firmware | **Yes** | Not in `linux-firmware`; still the root cause. |
| Local UCM files (`tas2783.conf`, patched `rt721.conf`, card override in `conf.d/amd-soundwire/`) | **No — harmful** | alsa-ucm-conf ≥ 1.2.15 (UCM Syntax 8) ships its own `tas2783.conf` and the kernel reports `spk:tas2783` in the card components, so the Speaker device appears on its own. `Headphone Switch` exists, so the `rt721.conf` patch's reason is gone. The bundled files target the older Syntax 7 layout: installing them makes the card's UCM config fail to load (`variable '${var:SpeakerCodecFile}' is not defined`), dropping audio back to Dummy Output. They also overwrite package-owned files that the next alsa-ucm-conf update reverts. |
| Boot-time ACP reset service | **No** | Firmware loads fine at boot here; the `FW download failed: -110` timeout was not seen. |
| Post-resume ACP reset service | **Optional** | See below. Also: the original hardcodes PCI `0000:c4:00.5`, while this laptop has the ACP at `0000:c3:00.5`; the copy here auto-detects it (`1022:15e2`). |

The firmware install location also differs: the kernel finds the blobs in
`/lib/firmware/` directly, so the extra copy in `ti/audio/tas2783/` is not
needed.

## Optional: speakers break after suspend/resume

The original project saw the whole `amd-soundwire` card vanish after s2idle
resume. If that happens to you (speakers back to "Dummy Output" after waking
the laptop), install the post-resume reset:

```bash
optional/install-resume-fix.sh
```

It installs `px13-audio-resume.service`, which after every resume unbinds and
rebinds the ACP PCI device and restarts PipeWire for logged-in users. This has
not been needed or verified on the tested setup. `./uninstall.sh` removes it.

## Known harmless log noise

Shortly after login the kernel may log bursts like:

```
soundwire sdw-master-0-1: Program transport params failed: -22
SDW1-PIN4-CAPTURE-SmartAmp: ASoC error (-22): at snd_soc_link_prepare()
```

That is PCM `hw:1,3`, the amps' feedback *capture* channel, being probed once.
It is not the speaker output (`hw:1,2`), is not used by the UCM profile, and
does not affect playback.

If the default output switches to **Headphones** when nothing is plugged in,
check `amixer -c1 cget name='Headphone Jack'`; select the Speaker sink with
`wpctl set-default <id>` (ids from `wpctl status`).

## Files

| Path | Purpose |
|---|---|
| `firmware/extract-firmware.py` | Extract `1714-1-{8,B}.bin` from the ASUS installer (stdlib only) |
| `install.sh` | Verify checksums and install the firmware into `/lib/firmware` |
| `uninstall.sh` | Remove the firmware (and the optional resume fix) |
| `optional/install-resume-fix.sh` | Install the post-resume ACP reset (only if needed) |
| `optional/px13-audio-fix.sh` | ACP reset + PipeWire restart (PCI address auto-detected) |
| `optional/px13-audio-resume.service` | Runs the reset after suspend/hibernate |

## Upstreaming

The real fix is getting the ASUS `1714-1-8` / `1714-1-B` blobs into
[`linux-firmware`](https://gitlab.com/kernel-firmware/linux-firmware).

## Licensing

The calibration firmware is proprietary to ASUS/TI and is deliberately not
distributed here; you extract it from ASUS's own driver for your own machine.
