#!/bin/bash
# tone-test.sh -- quiet per-speaker test tone for the iMac19,1 CS8409 driver.
#
#   sudo ./tone-test.sh          play the test with the CS8409 as it is
#   sudo ./tone-test.sh 0x62     first write DEV_CFG2 = 0x62 (ASP1/ASP2 on)
#
# Plays a quiet 440 Hz tone (-36 dBFS, with fades) on each of the 4 channels
# in turn, straight to the CS8409 (plughw:0,0, bypassing PipeWire). The raw
# device has NO volume control, so the level is fixed low in the WAV itself.
# Nothing here survives a reboot.
set -u
CODEC=/dev/snd/hwC0D0
WAV=/tmp/cs8409-tone.wav

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }
command -v python3 >/dev/null || { echo "python3 is needed: sudo pacman -S python"; exit 1; }
command -v hda-verb >/dev/null || { echo "hda-verb is needed: sudo pacman -S alsa-tools"; exit 1; }

# Keep the codec powered so our settings aren't lost to power-saving.
echo 0 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null

coef_get() { hda-verb $CODEC 0x47 0x500 "$1" >/dev/null 2>&1; hda-verb $CODEC 0x47 0xc00 0 2>/dev/null | awk '/value/ {print $3}'; }

echo "DEV_CFG2 before: $(coef_get 0x01)"
if [ $# -ge 1 ]; then
	hda-verb $CODEC 0x47 0x500 0x01 >/dev/null 2>&1
	hda-verb $CODEC 0x47 0x400 "$1" >/dev/null 2>&1
	echo "DEV_CFG2 set to $1, reads back: $(coef_get 0x01)"
fi

python3 - "$WAV" <<'EOF'
import math, struct, sys, wave
rate, ch, amp, f = 44100, 4, 10 ** (-36 / 20), 440.0
tone, gap, fade = int(1.0 * rate), int(0.6 * rate), int(0.05 * rate)
frames = bytearray()
for c in range(ch):
    for n in range(tone):
        env = min(1.0, n / fade, (tone - n) / fade)
        v = int(amp * env * math.sin(2 * math.pi * f * n / rate) * 2147483647)
        frames += struct.pack('<4i', *[v if k == c else 0 for k in range(ch)])
    frames += bytes(16 * gap)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(ch); w.setsampwidth(4); w.setframerate(rate)
w.writeframes(bytes(frames)); w.close()
EOF

echo
echo "Listen: one short beep per channel, in this order:"
echo "  1 = front-left   2 = front-right   3 = rear-left   4 = rear-right"
echo "Note which beeps you hear, and from which side (left/right, high/low)."
echo
if ! aplay -q -D plughw:0,0 "$WAV"; then
	echo
	echo "aplay failed. If it says 'busy', stop any audio/video playing and try again."
fi
echo "Done. DEV_CFG2 now: $(coef_get 0x01)"
