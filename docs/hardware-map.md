# iMac19,1 audio: hardware map

Everything here was measured on one iMac19,1 (27-inch, 2019, board `Mac-AA95B1DDAB278B95`)
under Omarchy, kernel `7.2.15-1-omarchy`, in November 2026. Register meanings marked
*(inferred)* come from the related, documented TI TAS5760 or from macOS-trace notes, not
from a datasheet for the exact part.

## Chips

| Part | Where | How confirmed |
|---|---|---|
| Intel HDA controller (Cannon Lake PCH) | PCI `8086:a348` at `00:1f.3`, PCI subsystem `8086:7270` | `lspci` |
| Cirrus Logic CS8409 HDA bridge | codec `0x10138409` rev `0x100100`, **codec subsystem `0x106b1000`** | `/proc/asound/card0/codec#0` |
| Cirrus Logic CS42L83 (headphones / headset) | I2C `0x48` (7-bit), chip ID `0x42A83` rev A | chip ID read over I2C |
| TI TAS5764L amp, left tweeter | I2C `0x6c` | ACK + register reads |
| TI TAS5764L amp, right tweeter | I2C `0x6d` | ″ |
| TI TAS5764L amp, left woofer | I2C `0x6e` | ″ |
| TI TAS5764L amp, right woofer | I2C `0x6f` | ″ |
| AMD Vega HDMI/DP audio | PCI `1002:aaf8` | works with the stock driver |

A full scan found nothing else on the CS8409's I2C bus. macOS's AppleHDA layout ID for this
machine is **16**.

## Speaker channels

| ALSA channel (4-channel stream) | Speaker | Amp reg `03` |
|---|---|---|
| 1 FL | left tweeter | `80` |
| 2 FR | right tweeter | `82` |
| 3 RL | left woofer | `81` |
| 4 RR | right woofer | `83` |

Confirmed by ear with a 440 Hz tone: channels 3–4 are clearly louder (woofers). Left and
right have not been checked by ear separately yet.

## HDA nodes

| Node | Role |
|---|---|
| `0x01` | Audio function group (AFG), owns the GPIOs |
| `0x02`, `0x03` | Speaker converters (ASP1), channels 0–1 and 2–3 of the stream |
| `0x24`, `0x25` | Speaker pins (`0x90100110`, `0x90100111`) |
| `0x0a` → `0x2c` | Headphone converter → headphone pin (`0x002b4020`), to the CS42L83 |
| `0x3c` | Headset mic pin (`0x00ab9030`) |
| `0x45` | Internal mic (DMIC2, `0x90a00100`) |
| `0x47` | Vendor widget: CS8409 coefficients, I2C master |

## CS8409 I2C master

- Address register: coef `0x59` (8-bit address, i.e. 7-bit × 2).
- Write: coef `0x5d` = `(reg << 8) | value`. Read: coef `0x5e` = `reg << 8`, then read coef `0x5e`.
- Status: coef `0x5c`. **`0x0038` = device answered (ACK), `0x0028` = no device (NACK).**
  Bit 4 is the ACK bit. The stock `cs8409_i2c_read()` treats both as success.
- I2C clock: bit 3 of coef `0x00`.

## GPIOs

| GPIO | Role |
|---|---|
| 0 | Input. Enabled by the macOS-derived driver, with an unsolicited event (probably the CS42L83 interrupt / jack detect) |
| 1 | **CS42L83 reset**, active low. Firmware leaves it floating, so it must be driven high. |
| 2, 3 | Inputs, enabled by the macOS-derived driver; role unknown |
| 4 | Output, driven high by firmware; role unknown (kept high) |

## TAS5764L registers *(inferred meanings)*

The register map is 32 bytes and repeats every `0x20`.

| Reg | Firmware leaves | Idle (this driver) | Playing | Meaning |
|---|---|---|---|---|
| `00` | `12` | `12` | `12` | ID / read-only |
| `01` | `fd` | `fc` | `fd` | Power: `fc` amp off, `fd` amp on |
| `02` | `44` | `44` | `44` | Digital control (input format) |
| `03` | `80` | `80/82/81/83` | same | Low bits: which TDM channel this amp plays |
| `04` | `5c` (≈ −57 dB) | `cf` | `cf` | Volume, `cf` = 0 dB, 0.5 dB steps |
| `05` | `00/10/20/30` | same | same | Per-amp value set by firmware (slot-related) |
| `06` | `51` | `55` | `55` | Analog control: PWM rate, gain (`55` = macOS) |
| `08` | `08` | `18` | `10` | Fault config; low bits are error flags (bit 3 = clock error) |
| `13` | `05` | `00` | `00` | Undocumented; macOS clears it |

## CS8409 vendor coefficients

| Coef | Firmware leaves | Idle (this driver) | Playing | Notes |
|---|---|---|---|---|
| `00` DEV_CFG1 | `9008` | `9000/9008` | same | PLL1 on; bit 3 = I2C clock |
| `01` DEV_CFG2 | `0000` | `0200` | `0220` | Port enables |
| `02` DEV_CFG3 | `0080` | `0280` | `0280` | Bus idle + GPIO_I2C |
| `03` ASP1_CLK_CTRL1 | `801f` | `8000` | `8000` | |
| `04` ASP1_CLK_CTRL2 | `083f` | `08ff` | `08ff` | Clock source / LRCK period |
| `05` ASP1_CLK_CTRL3 | `0000` | `0001` | `0001` | Bit-clock divider |
| `17` ASP1_SYNC_CTRL | `0000` | `0003` | `0003` | Converter sync |
| `19`–`1c` ASP1 A/B TX | `0400 0420 8c20 8000` | `8800 8820 8840 8860` | `0800 0820 0840 0860` | 4 slots at bit 0/32/64/96, 24-bit; bit 15 = slot off |
| `1d`–`20` ASP1 C/D TX | `8c40 8000 8c60 8000` | `8000` | `8000` | Unused |
| `6b` | — | `1200` | `1200` | Written `001f` at stream start; reads `1200` |
| `6d`, `6e` | `0000` | `0000` | `00ff` | Set during playback |
| `71` | `0000` | `400f` | `400f` | "TDM in use" flags |
| `82` pad config | `ff00` | `0000` | `5400` | ASP1 pads on during playback |
| `09` | `0013` | `0013` | `0013` | Unknown. The reference driver has `0093`; not needed for sound |
| `5b` I2C config | `0010` | `0200` | `0200` | I2C bus speed. This driver uses Dell's 100 kHz value (`0200`); the reference has `0010`. Both work |

Full dumps are in [`../logs/`](../logs/).

## Speaker start sequence (what made it play)

Matching the final register values was **not** enough; the order matters. At each stream
start, after the generic HDA code has programmed converters `0x02`/`0x03`:

1. Power the AFG (`0x01`) D3 → D0, then reprogram the converters' format and stream IDs.
2. Tweeter pair: the clock fields, slots `0x19`/`0x1a` = `0800`/`0820`, coef `82` |= `5400`,
   `DEV_CFG3` = `0280`, `DEV_CFG2` |= `0020`, pin `0x24` on, then coef `6b` = `001f`,
   coef `71` |= `400f`, vendor verb `0x7f0` = `b6`. Then the tweeter amps: reg `08` = `18`,
   reg `01` = `fd`.
3. Woofer pair: slots `0x1b`/`0x1c` = `0840`/`0860`, pin `0x25` on, the same three
   "TDM in use" writes, then the woofer amps on.
4. Converter sync: converters' stream IDs to 0, coef `17` = `0001`, then `0003`, stream IDs back.

The speaker stream is also kept off the headphone converter (`0x0a`), and GPIOs 0, 2 and 3
are enabled as inputs. At stream stop: amps off (reg `01` = `fc`), slots parked (`88xx`),
`DEV_CFG2` and coef `82` back to idle.

## Hazards

- **Run the speakers at 44.1 kHz only.** The speaker clock settings are 44.1 kHz ones
  (Apple's rate). At 48 kHz, PipeWire's default for video, the sound is distorted. Set
  `default.clock.allowed-rates = [ 44100 ]` (see `config/pipewire/50-imac-rate.conf`).

- **Never read CS42L83 register `0x2407`** (EQ_COEF_OUT0) or the rest of its EQ block. It
  makes the CS42L83 hold the I2C bus until it's reset. Seen twice, and recovered by holding
  GPIO1 low.
- The raw `hw:0,0` device has no volume control.
