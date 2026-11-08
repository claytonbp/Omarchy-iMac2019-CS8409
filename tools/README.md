# Tools

All scripts work with the driver installed. Those that need `sudo` say so when you run them.
Changes made by the scripts last until the next reboot, except `upmix-test.sh` and `eq.sh`,
which install PipeWire settings in your home folder (that's their job). All scripts assume the iMac's analog
card is card 0, as `aplay -l` showed on this machine.

| Script | What it does | Writes to hardware? |
|---|---|---|
| `check.sh` | Codec name, module file in use, DKMS status, this boot's driver log, playback devices | No |
| `tone-test.sh` | Quiet (−36 dBFS) 440 Hz beep on each of the 4 channels in turn, straight to the CS8409 | Turns HDA power-saving off; optional `DEV_CFG2` value as an argument |
| `capture.sh <label>` | Records CS8409 registers, GPIOs, converter/pin state and all 4 amps' registers, idle and while a tone plays → `~/capture-<label>.txt` | Power-saving off; I2C reads only |
| `upmix-test.sh` | Run as your normal user (no `sudo`). Installs the PipeWire upmix setting, switches the card to its 4-channel profile, plays a stereo test and measures the level PipeWire sends to each of the 4 channels (PASS/FAIL). Confirmed on the iMac (tweeters −35 dB, woofers −38 dB). | No (changes your PipeWire settings and default output) |
| `eq.sh [BASS TREBLE \| off]` | Run as your normal user. Bass and treble for the speakers, in dB (−12 to +8): adds the PipeWire output "iMac Speakers (EQ)" and makes it the default. Bass acts on the woofers, treble on the tweeters; changes apply live and are kept after a reboot. With no arguments it shows the setting. See INSTALL.md step 8. | No (changes your PipeWire settings and default output) |
| `switches.sh [name=value ...]` | Shows or changes the live speaker-start switches | Changes module options until reboot |
| `amp-test.sh`, `tdm-test.sh` | Experiments from the investigation that write amp volume and the TDM set-up from user space via `hda-verb`. Kept for reference; the driver does this properly now. | **Yes** |

## Live switches

```bash
./tools/switches.sh                          # show
sudo ./tools/switches.sh apple_afg_cycle=0   # change one
sudo ./tools/tone-test.sh                    # test the effect immediately
```

Each switch is read at the next stream start. See [`../driver/README.md`](../driver/README.md)
for what each one does.

## Comparing against the working reference

`logs/04-capture-reference-driver-playing.txt` is the state of the CS8409 and amps while a
known-good driver was playing on this iMac. If the speakers ever go silent after an update,
run `sudo ./tools/capture.sh now` and compare the `== PLAYING` sections:

```bash
diff <(sed -n '/== PLAYING/,/hw_params/p' logs/04-capture-reference-driver-playing.txt) \
     <(sed -n '/== PLAYING/,/hw_params/p' ~/capture-now.txt)
```
