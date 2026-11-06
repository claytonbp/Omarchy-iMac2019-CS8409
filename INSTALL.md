# Installing on a fresh Omarchy

For an **iMac19,1 (Retina 5K, 27-inch, 2019)**. Each step says what you should see, so you
can tell straight away if something is off.

## Before you wipe the iMac

Nothing in this repository needs the old system: the driver and settings are all here. Two
things are worth saving first, because they can't be published and can't be downloaded
later:

- **Wi-Fi firmware.** The BCM4364 Wi-Fi firmware comes from this iMac, not from the
  internet. Follow the "before you reinstall" parts of the
  [Wi-Fi guide](https://github.com/claytonbp/omarchy-imac2019-bcm4364) first.
- **Apple's speaker tuning files, if macOS is still on the iMac and the reinstall will erase
  it.** They're needed for the planned Apple-style crossover/EQ, not for anything in this
  guide. In macOS Terminal:
  ```bash
  mkdir -p ~/Desktop/imac-audio-apple && cd ~/Desktop/imac-audio-apple
  R=/System/Library/Extensions/AppleHDA.kext/Contents/Resources
  cp "$R/layout16.xml.zlib" "$R/Platforms.xml.zlib" .
  ioreg -lw0 > ioreg-full.txt
  ls -l
  ```
  Copy the folder to a USB stick or cloud storage. These are Apple's files: keep them
  private, don't add them to GitHub. If `cp` can't find a file, list the folder with
  `ls "$R" | grep -iE 'layout16|platforms'`.

### Making a USB copy

Optional, as everything is on GitHub, but useful to have with the Wi-Fi files. With the
stick mounted (for example as in the Wi-Fi guide, at `/mnt/usb`) and a network connection:

```bash
U=/mnt/usb/CS8409            # where the copy goes on the stick
rm -rf /tmp/cs8409-usb && git clone -q --depth 1 https://github.com/claytonbp/Omarchy-iMac2019-CS8409.git /tmp/cs8409-usb && rm -rf /tmp/cs8409-usb/.git
rm -rf "$U" && mkdir -p "$U" && cp -r /tmp/cs8409-usb/. "$U"/ && sync
(cd "$U" && sha256sum -c --quiet SHA256SUMS && echo "USB COPY OK")
```

This replaces any older `CS8409` folder on the stick, so the copy matches GitHub exactly.
`SHA256SUMS` lists a checksum for every file, so the copy can be checked again later, offline.

## 0. Before you start

- **Install Omarchy** as normal.
- **You need an internet connection** for step 3 (it installs packages). Use the iMac's
  Ethernet port, USB tethering from a phone, or Wi-Fi once it's set up with the
  [Wi-Fi guide](https://github.com/claytonbp/omarchy-imac2019-bcm4364).
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

You should see a kernel ending in `-omarchy` and starting with **7.2** (tested on this iMac)
or **7.3** (build-checked, not yet tested on the iMac). For anything newer, read
[Kernel updates](#kernel-updates) first: `install.sh` will stop on it. You should also see:

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

**Or from your USB copy** (see [Making a USB copy](#making-a-usb-copy)). Don't run it from
the stick: exFAT sticks can't store the "executable" flag, so scripts there give
"Permission denied". Copy it to your home folder, check it, and restore the flags:

```bash
U=/mnt/usb/CS8409            # the CS8409 folder on your stick
cp -r "$U" ~/Omarchy-iMac2019-CS8409
cd ~/Omarchy-iMac2019-CS8409
sha256sum -c --quiet SHA256SUMS && echo "COPY OK"
chmod +x install.sh tools/*.sh
```

`COPY OK` means every file is present and undamaged. Any `FAILED` line names a file that's
missing or different. Step 3 still needs an internet connection, because it installs packages.

## 3. Install

```bash
sudo ./install.sh
```

This does five things:

1. Checks for the iMac's CS8409 codec, and that the kernel is a 7.2 or 7.3 one.
2. Installs `base-devel`, `dkms`, `git`, `alsa-utils`, `alsa-tools`, `python`, `libpulse`
   and the headers for your running kernel (for Omarchy's kernel that's
   `linux-omarchy-headers`).
3. Builds the driver and installs it through **DKMS** as `cs8409-apple/0.9`, so it's rebuilt
   automatically after every kernel update, and checks that DKMS reports it `installed`.
4. Installs `/etc/modprobe.d/cs8409-apple.conf`.
5. Tells you to reboot.

At the end you should see lines like:

```
Installing /usr/lib/modules/7.2.15-1-omarchy/updates/dkms/snd-hda-codec-cs8409.ko.zst
Running depmod.... done.
```

DKMS may also print module-signing messages the first time (it creates its own signing
key). They're harmless.

<details>
<summary>Doing step 3 by hand instead</summary>

```bash
pacman -Qqo /usr/lib/modules/$(uname -r)/vmlinuz      # e.g. linux-omarchy
sudo pacman -S --needed base-devel dkms alsa-utils alsa-tools python libpulse linux-omarchy-headers
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
- under "Module file in use": `/lib/modules/<kernel>/updates/dkms/snd-hda-codec-cs8409.ko.zst`
- under "DKMS": `cs8409-apple/0.9, <kernel>, x86_64: installed`, and no WARNING line
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

The test scripts assume the iMac's analog card is **card 0**. It was on this machine
(`check.sh` lists `card 0: PCH [HDA Intel PCH]`). If yours shows the PCH card as card 1,
the scripts will report errors instead of playing.

## 7. Everyday sound: 44.1 kHz and all four speakers

Tested on this machine: 44.1 kHz cured the distortion on YouTube, a measured stereo test
reached all four channels, and after a reboot a 48 kHz sound still played at 44.1 kHz on
4 channels (the check at the end of this step).

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
copies to the rear at −3 dB); then `PASS`.

**After a reboot**, check both settings stuck. This plays a quiet 4-second 48 kHz tone (the
rate YouTube uses) through PipeWire and reads the speakers' state halfway through:

```bash
python3 -c "import math,struct,wave;w=wave.open('/tmp/t48.wav','wb');w.setnchannels(2);w.setsampwidth(2);w.setframerate(48000);w.writeframes(b''.join(struct.pack('<hh',v,v) for v in (int(1000*math.sin(2*math.pi*440*i/48000)) for i in range(48000*4))));w.close()"
paplay /tmp/t48.wav & sleep 2; cat /proc/asound/card0/pcm0p/sub0/hw_params; wait
```

It should show `channels: 4` and `rate: 44100 (44100/1)`, as it did on this iMac. (If you
read that file yourself at some other time and it only says `closed`, nothing was playing at
that moment: PipeWire closes the device a few seconds after sound stops.) If it still says
`closed` during the tone, PipeWire is sending sound elsewhere: check `pactl get-default-sink`
shows `alsa_output.pci-0000_00_1f.3.analog-surround-40`. If it shows `48000`, PipeWire
didn't pick up `~/.config/pipewire/pipewire.conf.d/50-imac-rate.conf`: check the file is
there, then restart PipeWire. As a quick test, `pw-metadata -n settings 0 clock.force-rate 44100`
forces the rate until PipeWire restarts.

This drives the tweeters and woofers with the same full-range signal, and the woofers sit
3 dB lower. Apple also splits the sound between them (a crossover) and adds EQ; recreating
that is a separate, later step. Until then, avoid very high volumes: the tweeters receive
bass they aren't built for.

**Volume:** use the normal desktop volume control (PipeWire). Never play loud material
straight to the raw `hw:0,0` / `plughw:0,0` device: it has no volume control.

## Kernel updates

DKMS rebuilds the driver for every new kernel. After an update and reboot, `./tools/check.sh`
prints a WARNING if the driver isn't installed for the running kernel.

| Kernel | Status |
|---|---|
| 7.2.x | **Tested** on this iMac (7.2.15) |
| 7.3.x | **Build-checked** against 7.3.1: the CS8409 files are identical and the bundled private headers are compatible. Not yet tested on the iMac. |
| 7.4 and later | **Not checked.** DKMS deliberately skips the build (`BUILD_EXCLUSIVE_KERNEL` in `driver/dkms.conf`), so the stock driver loads and the speakers go silent until the driver is updated. |

Why the limit: the driver bundles copies of a few private kernel headers
(`driver/src/common/`, `driver/src/codecs/`). If a new kernel changed the structures in them,
a module built with the old copies could compile fine and still misbehave. Refusing to build
is the safe failure.

To update the driver for a newer kernel:

1. Download that kernel's source from kernel.org and unpack it.
2. Copy its `sound/hda/codecs/cirrus/cs8409.c`, `cs8409.h` and `cs8409-tables.c` into
   `driver/src/codecs/cirrus/`, and its private headers into place, replacing the old copies:
   `sound/hda/common/hda_local.h`, `hda_auto_parser.h`, `hda_jack.h` → `driver/src/common/`;
   `sound/hda/codecs/generic.h` → `driver/src/codecs/`;
   `sound/hda/codecs/side-codecs/hda_component.h` → `driver/src/codecs/side-codecs/`.
3. Re-apply the three small hooks: from inside `driver/src/codecs/cirrus/`, run
   `patch -p5 < ../../../apple-changes.patch` (or edit them in by hand).
4. Widen the pattern in `driver/dkms.conf` (`BUILD_EXCLUSIVE_KERNEL`) and the matching check
   in `install.sh` to include the new version.
5. Run `make` in `driver/` to test-build, then `sudo make install`, reboot, and run
   `./tools/check.sh` and `sudo ./tools/tone-test.sh`.

## Removing the driver

```bash
sudo ./install.sh --remove
```

Then reboot. The stock driver comes back. To remove the PipeWire settings from step 7 too
(as your normal user):

```bash
rm -f ~/.config/pipewire/pipewire.conf.d/50-imac-rate.conf \
      ~/.config/pipewire/client.conf.d/50-imac-upmix.conf \
      ~/.config/pipewire/pipewire-pulse.conf.d/50-imac-upmix.conf
systemctl --user restart pipewire pipewire-pulse wireplumber
```

## Troubleshooting

| Symptom | What to do |
|---|---|
| `check.sh` still shows `Codec: Cirrus Logic CS8409` (no `/CS42L83`) | You haven't rebooted since installing, or DKMS didn't build: check `dkms status`. |
| `install.sh` says the kernel isn't one it has been checked against | Your kernel is newer than 7.3. See [Kernel updates](#kernel-updates). |
| `check.sh` warns the driver isn't installed for the running kernel | If the kernel is 7.4 or later, see [Kernel updates](#kernel-updates). Otherwise the headers were probably missing when the kernel updated: install `<kernel-package>-headers`, run `sudo dkms autoinstall`, and reboot. |
| Distorted sound in videos | PipeWire is running at 48 kHz. See the check at the end of [step 7](#7-everyday-sound-441-khz-and-all-four-speakers). |
| Thin sound, no bass | Only the tweeters are playing: the card is on its stereo profile, or the upmix setting is missing. Redo [step 7](#7-everyday-sound-441-khz-and-all-four-speakers). |
| `CS42L83 ... no answer` | The reset pin setting didn't apply. Check `cat /sys/module/snd_hda_codec_cs8409/parameters/apple_cs42l83_reset_gpio` prints `1`. |
| `I2C bus LOST` in the log | Send the log upstream; the driver tries to recover by itself. |
| `tone-test.sh` says the device is busy | Stop anything that's playing, then try again. |
| Silence, but the log looks fine | Run `sudo ./tools/capture.sh mine` and compare `~/capture-mine.txt` with [`logs/04-capture-reference-driver-playing.txt`](logs/04-capture-reference-driver-playing.txt). |

The live switches in [`tools/README.md`](tools/README.md) let you change the start sequence
without a reboot, which helps narrow down a fault.
