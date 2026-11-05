# cs8409-apple driver

An out-of-tree build of Linux's `snd-hda-codec-cs8409` module with an Apple iMac19,1 path
added. It replaces the stock module (DKMS installs it under `updates/`, which takes
priority) and leaves the Dell support untouched.

## Files

| File | Origin |
|---|---|
| `src/codecs/cirrus/cs8409_apple.c` | **New.** All Apple code: fixup, init, I2C helpers, diagnostics, speaker start/stop. |
| `src/codecs/cirrus/cs8409.c`, `cs8409.h`, `cs8409-tables.c` | Linux 7.2.15, plus three small hooks (see `apple-changes.patch`) |
| `src/common/hda_local.h`, `hda_auto_parser.h`, `hda_jack.h` | Linux 7.2.15 private HDA headers, unchanged |
| `src/codecs/generic.h`, `src/codecs/side-codecs/hda_component.h` | Linux 7.2.15, unchanged |
| `Kbuild`, `Makefile`, `dkms.conf` | Out-of-tree build and DKMS packaging |
| `apple-changes.patch` | Every change made to the stock kernel files |

The three hooks in the stock files are:

- `HDA_CODEC_QUIRK(0x106b, 0x1000, ...)` in the quirk table. It matches the **codec**
  subsystem ID, because the iMac's PCI subsystem ID is Intel's own (`8086:7270`).
- A `CS8409_APPLE` fixup ID and model name `apple`.
- `#include "cs8409_apple.c"` in `cs8409.c`, so the Apple code can use the static I2C helpers.

## Supported kernels

`dkms.conf` sets `BUILD_EXCLUSIVE_KERNEL="^7\.[23]([.-]|$)"`: DKMS builds only for 7.2.x and
7.3.x. The private headers bundled here are from 7.2.15. They're unchanged in 7.3.1 apart
from a new helper function in `hda_local.h` and a changed `snd_hda_get_pin_label()`
prototype in `hda_auto_parser.h`, which this driver doesn't call; the CS8409 files are
identical. On other kernels DKMS skips the build (exit 77) and the stock driver loads. To
move to a newer kernel, see [INSTALL.md, Kernel updates](../INSTALL.md#kernel-updates).

## Build

```bash
make                 # build against the running kernel, no install
sudo make install    # install via DKMS (removes any older cs8409-apple version first)
sudo make uninstall  # remove; the stock module comes back after a reboot
```

## Module options

Set them in `/etc/modprobe.d/cs8409-apple.conf` (`options snd_hda_codec_cs8409 ...`) and
reboot. Options marked **live** are re-read at every stream start, so you can also change
them through `/sys/module/snd_hda_codec_cs8409/parameters/` (or `tools/switches.sh`).

| Option | Default | Meaning |
|---|---|---|
| `apple_cs42l83_reset_gpio` | `1` | CS8409 GPIO holding the CS42L83 in reset; driven high at init |
| `apple_amp_volume` | `0xcf` | TAS5764L volume, register `04` (`0xcf` = 0 dB, 0.5 dB steps) |
| `apple_spk_hook` | `1` | **live** Run the speaker start/stop sequence around playback |
| `apple_spk_order` | `1` | **live** `1` = macOS order (each pair's slots, then its amps on, sync last); `0` = slots, sync, amps |
| `apple_afg_cycle` | `1` | **live** Power the audio function D3 → D0 at stream start and reprogram the converters |
| `apple_hp_off` | `1` | **live** Keep the speaker stream off the headphone converter (`0x0a`) and pin `0x2c` |
| `apple_gpio_inputs` | `1` | **live** Enable GPIO 0, 2, 3 as inputs |
| `apple_i2c` | `1` | Bring up the CS8409 I2C bus (`0` skips all I2C: safest fallback) |
| `apple_probe` | `1` | Read and log the CS42L83 chip ID and amp ID at boot (read-only) |
| `apple_dump` | `0` | Log the CS8409 vendor registers and GPIOs at boot (read-only) |
| `apple_scan` | `0` | Scan the whole I2C bus at boot (read-only) |
| `apple_regdump` | `0` | Dump CS42L83 and amp registers at boot (read-only; skips the CS42L83 EQ block) |
| `apple_gpio_probe` | `0` | Raise each unused GPIO briefly and report new I2C devices (how GPIO1 was found) |
| `apple_cs42l83_addr` | `0x48` | CS42L83 7-bit I2C address |
| `apple_amp_addr` | `0x6c` | First amp's 7-bit I2C address; the others are +1, +2, +3 |
| `apple_amp_reset_gpio` | `-1` | Amp reset GPIO, if one is ever found (`-1` = none) |
| `apple_dev_cfg2` | `-1` | Force a `DEV_CFG2` value at init (experiments only) |
| `model=apple` | — | Force the Apple path on a different codec ID |

Which of the four live switches are strictly needed hasn't been isolated yet. All four on
is the tested combination.

## Logging

```bash
journalctl -k -b | grep 'apple:'
```

Every line from this code starts with `apple:`. The `init #N` line counts how often the
codec has been (re)initialised. That happens at boot, on resume, and after every runtime
power-save wake-up.

## Never do this

Don't read CS42L83 register `0x2407` (EQ_COEF_OUT0) or anything else in its EQ block. It
makes the CS42L83 hold the I2C bus until it's reset. The register-dump code skips that block
on purpose.
