# Omarchy-iMac2019-CS8409

Internal speaker audio for the **Apple iMac19,1 (Retina 5K, 27-inch, 2019)** running
**Omarchy** (Arch Linux). This is a self-written Linux driver for the iMac's Cirrus Logic
CS8409 audio bridge, built and tested on one machine, step by step, in November 2026.

| | Out of the box | With this driver |
|---|---|---|
| Internal speakers (4) | silent: the stock driver never sets up the amplifiers | **working** |
| Everyday stereo (YouTube, music) | — | **working**: PipeWire at 44.1 kHz + 4-channel upmix ([INSTALL.md step 7](INSTALL.md#7-everyday-sound-441-khz-and-all-four-speakers)) |
| Headphone jack | silent | not done yet |
| Internal / headset microphone | not working | not done yet |
| Suspend / resume | — | not tested yet (the driver re-runs its setup on wake) |
| Apple's speaker tuning (crossover/EQ) | — | not done yet |

Tested on kernel `7.2.15-1-omarchy` with PipeWire. Build-checked against Linux 7.3.1 (not yet
run on the iMac). Newer kernels are refused until checked: see
[INSTALL.md, Kernel updates](INSTALL.md#kernel-updates).

## Quick start (fresh Omarchy)

Before wiping the iMac, read [Before you wipe the iMac](INSTALL.md#before-you-wipe-the-imac)
(Wi-Fi firmware, and Apple's tuning files if macOS will be erased). Then, with a network
connection:

```bash
git clone https://github.com/claytonbp/Omarchy-iMac2019-CS8409.git
cd Omarchy-iMac2019-CS8409
sudo ./install.sh
# reboot
./tools/check.sh
sudo ./tools/tone-test.sh
# then, as your normal user: INSTALL.md step 7 (44.1 kHz + all four speakers)
```

Full step-by-step instructions, including what to check after each step and how to
set up PipeWire for everyday listening (44.1 kHz, all four speakers): **[INSTALL.md](INSTALL.md)**.

## What's in here

| Path | What it is |
|---|---|
| [`install.sh`](install.sh) | One-step installer: build tools, kernel headers, driver (DKMS), settings |
| [`INSTALL.md`](INSTALL.md) | Full instructions for a fresh Omarchy install |
| [`driver/`](driver/) | The driver source: Linux 7.2.15 CS8409 files + [`cs8409_apple.c`](driver/src/codecs/cirrus/cs8409_apple.c) |
| [`config/`](config/) | modprobe settings, and the PipeWire 44.1 kHz and upmix settings |
| [`tools/`](tools/) | Check, test, capture and live-switch scripts |
| [`docs/hardware-map.md`](docs/hardware-map.md) | Every chip, address, register and value measured on this iMac |
| [`docs/how-it-was-found.md`](docs/how-it-was-found.md) | How the driver was worked out, version by version |
| [`docs/chat-transcript.md`](docs/chat-transcript.md) | The full conversation in which this was built |
| [`logs/`](logs/) | Raw diagnostic output and register captures from the machine |

## How it works, briefly

The iMac's audio runs through a Cirrus Logic **CS8409** HDA bridge. Behind it, on the
bridge's own I2C bus, sit a **CS42L83** headphone codec and four **TI TAS5764L** amplifiers
(left/right tweeter, left/right woofer). Linux's stock `snd-hda-codec-cs8409` driver only
knows Dell's wiring of the same bridge, so on this iMac the amplifiers are never set up.

This driver adds an Apple path, matched on the codec subsystem ID `0x106b1000`, that:

1. releases the CS42L83 from reset (GPIO1) and brings up the bridge's I2C bus,
2. puts the CS8409 clocks and the four TDM speaker slots into a known idle state,
3. sets up each amplifier (gain, volume, TDM channel) and leaves it switched off,
4. at every playback start, runs the macOS start sequence (slots on, amps on, converter
   sync), and at every stop switches the amps off again.

## Credits

The register values in step 4 come from the macOS-trace notes in
[davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) (GPL-2.0), and
were confirmed by capturing that driver's state on this machine. See [CREDITS.md](CREDITS.md).

## Licence

GPL-2.0, as the driver is derived from Linux kernel sources. See [LICENSE](LICENSE).

**Use at your own risk.** This loads an out-of-tree kernel module and has been tested on
exactly one iMac19,1.
