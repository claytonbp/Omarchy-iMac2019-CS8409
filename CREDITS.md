# Credits

- **Linux kernel CS8409 driver** (Cirrus Logic and the ALSA maintainers): the base files in
  `driver/src/`, GPL-2.0. The Apple path is added alongside the Dell code without changing it.
- **[davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro)** (GPL-2.0):
  its notes from macOS traces of `AppleHDATDMBusManagerCS8409` and the TAS5764L amp set-up
  are the source of the speaker start sequence and the amp register values used here. Its
  driver (commit `89b22ff`) was also installed temporarily on this iMac as a measuring tool.
  Its register state while playing ([`logs/04-...`](logs/04-capture-reference-driver-playing.txt))
  is what this driver was matched against. No code was copied; the values and sequence were
  re-implemented in `cs8409_apple.c`.
- **[MrHogun/imac-a2115-linux](https://github.com/MrHogun/imac-a2115-linux)**: independent
  confirmation of the iMac19,1 amp addresses and channel layout, and of the suspend issue.
- **Texas Instruments TAS5760 datasheet**: the closest public documentation for the
  TAS5764L's register map, used to interpret the amp registers.
- Built by the iMac's owner with Claude (Anthropic), November 2026. See
  [`docs/chat-transcript.md`](docs/chat-transcript.md).
