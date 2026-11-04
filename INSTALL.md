# Installing on a fresh Omarchy

For an **iMac19,1 (Retina 5K, 27-inch, 2019)**. Each step says what you should see, so you
can tell straight away if something is off.

## 0. Before you start

- **Install Omarchy** as normal.
- **You need an internet connection.** The iMac's Broadcom BCM4364 Wi-Fi doesn't work
  out of the box on Linux, so use Ethernet or USB tethering from a phone until Wi-Fi is set
  up. Wi-Fi isn't covered here.
- **Update first and reboot**, so the running kernel and its headers match:
  ```bash
  sudo pacman -Syu
  ```
  Then reboot.

## 1. Check the hardware

```bash
uname -r
cat /proc/asound/card*/codec#0 | grep -E 'Codec|Subsystem'
```

You should see a kernel ending in `-omarchy`, and:

```
Codec: Cirrus Logic CS8409
Subsystem Id: 0x106b1000
Codec: ATI R6xx HDMI
...
```

`0x106b1000` is the iMac's CS8409. If you don't see it, stop: this driver won't apply.

## 2. Get this repository

```bash
sudo pacman -S --needed git
git clone https://github.com/claytonbp/Omarchy-iMac2019-CS8409.git
cd Omarchy-iMac2019-CS8409
```

## 3. Install

```bash
sudo ./install.sh
```

This does four things:

1. Installs `base-devel`, `dkms`, `git`, `alsa-utils`, `alsa-tools`, `python` and the
   headers for your running kernel (for Omarchy's kernel that's `linux-omarchy-headers`).
2. Builds the driver and installs it through **DKMS** as `cs8409-apple/0.9`, so it's rebuilt
   automatically after every kernel update.
3. Installs `/etc/modprobe.d/cs8409-apple.conf`.
4. Tells you to reboot.

At the end you should see lines like:

```
Installing /usr/lib/modules/7.2.15-1-omarchy/updates/dkms/snd-hda-codec-cs8409.ko.zst
Running depmod.... done.
```

You may see `Deprecated feature` or module-signing messages from DKMS; they're harmless.

<details>
<summary>Doing step 3 by hand instead</summary>

```bash
pacman -Qqo /usr/lib/modules/$(uname -r)/vmlinuz      # e.g. linux-omarchy
sudo pacman -S --needed base-devel dkms alsa-utils alsa-tools python linux-omarchy-headers
cd driver
make                  # test build only
sudo make install     # install via DKMS
cd ..
sudo cp config/modprobe.d/cs8409-apple.conf /etc/modprobe.d/
```
</details>

## 4. Reboot

The driver is loaded at boot. Until you reboot, the stock driver is still running.

## 5. Check the driver

```bash
./tools/check.sh
```

You should see:

- `Codec: Cirrus Logic CS8409/CS42L83` (the new name shows the Apple path is active)
- `Module file in use: .../updates/dkms/...`
- `cs8409-apple/0.9 ... installed`
- in the log:
  - `apple: Apple path selected (codec SSID 0x106b1000)`
  - `apple: CS42L83 reset released on gpio1: answering at 0x48`
  - `apple: CS42L83 chip id 0x42a83 (CS42L83, OK)`
  - four `amp ... sts=0038 reg00=12` lines
  - `apple: bus check at end of init #1: ok`

Two lines saying `loading out-of-tree module taints kernel` and `module verification
failed` are normal for any module you build yourself.

## 6. Test the speakers

```bash
sudo ./tools/tone-test.sh
```

This plays a quiet beep on each of the four channels in turn:

| Beep | Channel | Speaker |
|---|---|---|
| 1 | front-left | left tweeter (quieter at this pitch) |
| 2 | front-right | right tweeter (quieter) |
| 3 | rear-left | left woofer (louder) |
| 4 | rear-right | right woofer (louder) |

The woofers sound louder because the test note (440 Hz) is low for a tweeter. If you hear
nothing, see [Troubleshooting](#troubleshooting).

## 7. Everyday sound: 44.1 kHz and all four speakers

Tested on this machine: YouTube and a measured stereo test through PipeWire.

Run these as your **normal user** (not with `sudo`). They need two PipeWire settings:

- **44.1 kHz only.** The driver's speaker clocks are set up for 44.1 kHz, the rate Apple
  uses. At PipeWire's usual 48 kHz (YouTube, most video) the sound is **distorted**. This
  setting makes PipeWire convert everything to 44.1 kHz first.
- **Stereo on all four speakers.** PipeWire's stereo profile only drives channels 1–2 (the
  tweeters), which sounds thin. The 4-channel profile plus "upmix" copies stereo to the
  woofers as well.

```bash
# 44.1 kHz only
mkdir -p ~/.config/pipewire/pipewire.conf.d
cp config/pipewire/50-imac-rate.conf ~/.config/pipewire/pipewire.conf.d/

# copy stereo to the rear (woofer) channels
mkdir -p ~/.config/pipewire/client.conf.d ~/.config/pipewire/pipewire-pulse.conf.d
cp config/pipewire/50-imac-upmix.conf ~/.config/pipewire/client.conf.d/
cp config/pipewire/50-imac-upmix.conf ~/.config/pipewire/pipewire-pulse.conf.d/

systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 3

# 4-channel output profile (WirePlumber remembers it)
pactl set-card-profile alsa_card.pci-0000_00_1f.3 output:analog-surround-40+input:analog-stereo
```

If `pactl` says the profile name doesn't exist, list the real names with
`pactl list cards | grep -A30 'Profiles:'`.

**Check it** with `bash tools/upmix-test.sh` (normal user). It installs the upmix setting
too, plays a stereo test and measures each channel. Expected: hardware `rate: 44100`,
`channels: 4`; tweeters around −35 dB and woofers about **3 dB lower** (PipeWire's upmix
copies to the rear at −3 dB); then `PASS`. While music plays,
`cat /proc/asound/card0/pcm0p/sub0/hw_params` should show `rate: 44100`.

This drives the tweeters and woofers with the same full-range signal, and the woofers sit
3 dB lower. Apple also splits the sound between them (a crossover) and adds EQ; recreating
that is a separate, later step. Until then, avoid very high volumes: the tweeters receive
bass they aren't built for.

**Volume:** use the normal desktop volume control (PipeWire). Never play loud material
straight to the raw `hw:0,0` / `plughw:0,0` device: it has no volume control.

## Kernel updates

DKMS rebuilds the driver for every new kernel. Check after an update with
`dkms status cs8409-apple`, which should list the new kernel as `installed`.

The driver source is from Linux 7.2.15. It normally builds on later 7.2.x kernels. If a
DKMS build ever fails on a newer kernel:

1. Download that kernel's source from kernel.org.
2. Copy its `sound/hda/codecs/cirrus/cs8409.c`, `cs8409.h` and `cs8409-tables.c` into
   `driver/src/codecs/cirrus/`, and the private headers listed in
   [`driver/README.md`](driver/README.md) into place.
3. Re-apply the three small hooks with `patch -p5 < ../../../apple-changes.patch` from inside
   `driver/src/codecs/cirrus/` (or edit them in by hand).
4. Run `sudo make install` in `driver/`.

## Removing the driver

```bash
sudo ./install.sh --remove
```

Then reboot. The stock driver comes back.

## Troubleshooting

| Symptom | What to do |
|---|---|
| `check.sh` still shows `Codec: Cirrus Logic CS8409` (no `/CS42L83`) | You haven't rebooted since installing, or DKMS didn't build: check `dkms status`. |
| `dkms status` doesn't list your kernel | The headers were missing when the kernel updated. Install `<kernel-package>-headers`, then run `sudo dkms autoinstall` and reboot. |
| `CS42L83 ... no answer` | The reset pin setting didn't apply. Check `cat /sys/module/snd_hda_codec_cs8409/parameters/apple_cs42l83_reset_gpio` prints `1`. |
| `I2C bus LOST` in the log | Send the log upstream; the driver tries to recover by itself. |
| `tone-test.sh` says the device is busy | Stop anything that's playing, then try again. |
| Silence, but the log looks fine | Run `sudo ./tools/capture.sh mine` and compare `~/capture-mine.txt` with [`logs/04-capture-reference-driver-playing.txt`](logs/04-capture-reference-driver-playing.txt). |

The live switches in [`tools/README.md`](tools/README.md) let you change the start sequence
without a reboot, which helps narrow down a fault.
