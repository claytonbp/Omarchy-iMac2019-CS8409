# How the driver was worked out

A version-by-version record of the investigation, done on the iMac itself on 4 November 2026.
Every step was read-only until the hardware was understood. The full conversation is in
[`chat-transcript.md`](chat-transcript.md).

## Starting point

- macOS `ioreg` (SystemInfo.txt) showed the chain: Intel HDA → Cirrus CS8409
  (`0x10138409`, subsystem `0x106b1000`, layout 16) → 4× TAS5764L amps
  (`AppleHDATDMAmpTAS5764L` = 4), plus the CS42L83 headphone codec implied by the design.
- On Omarchy the stock `snd-hda-codec-cs8409` loaded, named the codec `Cirrus Logic CS8409`,
  and made a sink appear, but there was no sound: it only knows Dell's wiring.
- The aim was a driver of the owner's own rather than an install script from GitHub.

## v0.1: bind without touching anything

- Built the 7.2.15 CS8409 sources out of tree, with a new `cs8409_apple.c` included from
  `cs8409.c` so it could use the static I2C helpers.
- **Finding:** the PCI subsystem ID is Intel's (`8086:7270`); `0x106b1000` is the *codec's*
  subsystem ID. A normal `SND_PCI_QUIRK` would never match, so the quirk is
  `HDA_CODEC_QUIRK(0x106b, 0x1000, …)`.
- Result: the Apple path was selected and the codec renamed `CS8409/CS42L83`. All four amps
  answered at `0x6c`–`0x6f` (`reg00 = 12`). The CS42L83 read back `00 00 00`.

## v0.2: an honest I2C read

- The stock helper treats any finished I2C transfer as success. v0.2 logged the CS8409's
  I2C status register for every read and scanned the bus.
- **Finding:** status `0x0038` = ACK, `0x0028` = NACK. Only the four amps were on the bus;
  the CS42L83 wasn't answering at all. GPIO state: only GPIO4 was in use (output high).
- Log: [`logs/01-check-v0.2-i2c-scan.txt`](../logs/01-check-v0.2-i2c-scan.txt)

## v0.3: find the CS42L83 reset line

- Raised each unused GPIO for 20 ms, one at a time, scanned the bus, and restored it.
- **Finding:** GPIO1 high → a device appeared at `0x48`. With GPIO1 held high, it read chip
  ID **`0x42A83`**: a CS42L83, revision A. GPIO1 is its active-low reset.

## v0.4 / v0.5: register dumps, and a bus that died

- v0.4 dumped the CS42L83 and amp registers. Partway through the CS42L83 dump every read
  failed, amps included.
- v0.5 dumped the amps first and detected bus loss, then tried three recoveries. Only holding
  the CS42L83 in reset brought the bus back.
- **Findings:**
  - Reading CS42L83 register `0x2407` (EQ_COEF_OUT0) makes the chip jam the I2C bus. It
    happened at the same register both times, and that block is now never touched.
  - The CS42L83 sits at factory defaults (power `ff`, mixer muted): it needs a full init for
    headphones.
  - Each amp has a 32-byte register map (it repeats every `0x20`). The four amps are identical
    except reg `05` (`00/10/20/30`), so the firmware had programmed them for the startup chime.
- Logs: [`02`](../logs/02-check-v0.4-register-dumps.txt), [`03`](../logs/03-check-v0.5-bus-jam-found.txt)

## v0.6: first-sound attempts from user space (silent)

| Attempt | Result |
|---|---|
| `tone-test.sh`: four quiet beeps, with and without the CS8409 ports enabled (`DEV_CFG2` = `0x62`) | Silent |
| `amp-test.sh`: amp volume reg `04` raised from `5c` (≈ −57 dB) to up to `bf` | Writes confirmed (`9f`/`af`/`bf` read back), still silent. Amp reg `08` showed the clock-error flag. |
| `tdm-test.sh`: replayed macOS's CS8409 set-up from davidjo's trace notes via `hda-verb` | Clock-error flag cleared, still silent |

Conclusion: the remaining steps happen inside the driver at stream start (format rewrite,
converter sync), which a script beside `aplay` can't time correctly.

## Measuring a working driver

- davidjo's driver (commit `89b22ff`) was installed **temporarily**, only as a measuring tool.
  With it, the same quiet tone was audible.
- `capture.sh` recorded the CS8409 coefficients, GPIOs, converter and pin state, and all amp
  registers, idle and while playing.
- Log: [`logs/04-capture-reference-driver-playing.txt`](../logs/04-capture-reference-driver-playing.txt)

## v0.7: same registers, still silent

- Filled the init tables and a playback hook with the measured values; switched back to the
  own driver.
- **Finding:** a capture while playing matched the reference in every audio-path setting
  (all 32 registers of each amp, the clocks, the four slots, the unknown `6b`/`6d`/`6e`), but
  it was still silent. So the order of operations matters, not just the final values.
- At the time this was described as a match "register for register". The final check (below)
  found that was too strong: CS8409 coef `09` (`0013` vs `0093`) and the I2C bus-speed
  register `5b` (`0200` vs `0010`) also differed, besides the GPIO and headphone-pin
  differences that became v0.8 switches. v0.8 plays with both still different, so neither is
  needed for sound.
- Log: [`logs/05-capture-own-driver-v0.7-silent.txt`](../logs/05-capture-own-driver-v0.7-silent.txt)

## v0.8: macOS's order → sound

Four differences remained, each added as a live switch, defaulting to the reference behaviour:

1. Order: each amp pair's slots, then that pair's amps on, then the converter sync last
   (v0.7 synced first and switched amps on last).
2. Power the audio function D3 → D0 at stream start and reprogram the converters.
3. Keep the stream off the headphone converter (the generic code mirrored it there).
4. Enable GPIOs 0, 2, 3 as inputs.

**Result: all four speakers played** (`tone-test.sh`). Beeps 3–4 (woofers) were louder at
440 Hz, as expected. Which of the four switches is strictly required hasn't been isolated yet.

## v0.9: packaged

- GPIO1 is now the default CS42L83 reset pin, and the boot-time register dump is off.
- One-step `install.sh` for a fresh Omarchy install.

## After v0.9: everyday listening

- **Distortion on YouTube.** `hw_params` showed the speakers running at **48 kHz**; every earlier
  test had used 44.1 kHz, the rate the clock settings came from. Forcing PipeWire to 44.1 kHz
  (`pw-metadata -n settings 0 clock.force-rate 44100`) cleared it. Now permanent in
  `config/pipewire/50-imac-rate.conf`.
- **Thin sound.** The stereo profile only drives the tweeters. The 4-channel profile plus
  PipeWire's `channelmix.upmix` (method `simple`) copies stereo to the woofers. Measured from the
  sink monitor: tweeters −35.2 dB, woofers −38.2 dB; the simple upmix copies to the rear at −3 dB.
- A measurement pitfall: `parec --channels=4` without `--channel-map` records PulseAudio's
  default 4-channel layout (FL, FC, FR, RC), not FL/FR/RL/RR. That briefly made a working set-up
  look as if the right tweeter were silent.

- **Bass and treble (8 November).** The sound was clear but flat. `tools/eq.sh` adds a
  PipeWire filter-chain output in front of the 4-channel speakers: a low shelf at 150 Hz on the
  woofers (bass), a high shelf at 4 kHz on the tweeters (treble), and low cuts at 80 Hz
  (tweeters) and 40 Hz (woofers). Each boost lowers the rest of that speaker by the same
  amount, plus 1 dB of headroom for the small rise the low cuts add, so nothing can reach full
  scale. Measured on a stand-in PipeWire 1.0.5 with a fake 4-channel sink of the same name,
  using noise and full-scale sweeps: the response matched the design at every setting, the
  peaks stayed at or below full scale, there was no crosstalk between left and right, and live
  changes, restarts and `off` all behaved. WirePlumber keeps the equaliser's volume (checked
  in 0.4.17 here and in the 0.5.19 source); if that saved volume is lost, 0.5 starts it at 50%.
  Not yet heard on the iMac.

## Final check (5 November 2026)

Before the iMac was reinstalled, the repository was cloned fresh from GitHub and checked
end to end.

**Confirmed:**

- The repository is public: it clones and its files download without logging in.
- The driver source differs from the v0.8 that was heard working in only the two intended
  defaults (CS42L83 reset on GPIO1; boot-time register dump off).
- Stock 7.2.15 plus `apple-changes.patch` reproduces the three edited kernel files exactly.
  The five bundled headers are byte-identical to 7.2.15.
- It builds from the clone with no compiler warnings, and every documented option default
  matches the code.
- Each expected log line in INSTALL.md is printed, word for word, by the code.

**Found and fixed:**

| Finding | Fix |
|---|---|
| Linux 7.3.1 is out, so a fresh install may not get 7.2 | Compared every file the driver depends on with 7.3.1 (only harmless changes) and test-built against it: clean. DKMS now builds only for 7.2.x/7.3.x and skips newer kernels instead of building with out-of-date private headers; `install.sh` checks too. Tested with DKMS: builds on 7.2.15 and 7.3.1, skips 7.4. |
| GitHub listed the licence as "Other" | `LICENSE` is now the plain GPL-2.0 text, without the kernel's header lines |
| `install.sh` only looked at the first sound card for the codec | It now checks all cards |
| `pactl`/`parec` (`libpulse`) weren't installed explicitly | Added to `install.sh` |
| Nothing confirmed DKMS actually installed the module | `install.sh` checks `dkms status`; `check.sh` warns if the running kernel has no build |
| The "44.1 kHz" setting had been tested live, not across a reboot | Checked after a reboot: a 48 kHz test tone played at `rate: 44100`, `channels: 4`. That test is now the check in INSTALL.md step 7 |
| Wi-Fi firmware and Apple's tuning files would be lost in a full wipe | "Before you wipe the iMac" section in INSTALL.md |
| The v0.7 "register for register" claim was too strong | Corrected above and in the transcript |
| The transcript claimed replies were "as given" and had one reply wrong and several messages missing | Marked as a condensed record, the wrong reply restored, every message included |
| `tools/README.md` said nothing survives a reboot | `upmix-test.sh` installs PipeWire settings; now stated |

## Still to do

1. Apple's layout-16 tuning (crossover, EQ, unity-gain woofers) as a PipeWire filter-chain, to
   replace the plain upmix and the simple bass/treble equaliser.
2. Isolate which start-sequence switches are needed, and trim the diagnostics.
3. Suspend/resume test.
4. Headphones: CS42L83 init (CS42L42-compatible; avoid the EQ block) and jack detection
   (probably GPIO0).
5. Internal and headset microphones.
