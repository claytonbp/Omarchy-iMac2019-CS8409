#!/bin/bash
# upmix-test.sh -- set up "stereo on all four speakers" and measure it.
# Run as your normal user (no sudo):  bash upmix-test.sh
#
# 1. Installs the PipeWire upmix setting (stereo copied to the rear = woofer
#    channels) in ~/.config/pipewire/, and restarts PipeWire.
# 2. Switches the CS8409 card to its 4-channel profile and makes it the default.
# 3. Plays a STEREO test sound (a low tone, then a high tone) through PipeWire,
#    records what PipeWire sends to each of the four channels, and reports the
#    level per channel. If the woofer channels (RL/RR) carry signal, it works.
#
# Undo: delete ~/.config/pipewire/{client,pipewire-pulse}.conf.d/50-imac-upmix.conf,
# restart PipeWire, and pick the "Analog Stereo" profile again.
set -u

for t in pactl parec paplay python3 systemctl; do
	command -v $t >/dev/null || { echo "Missing '$t' (pactl/parec/paplay are in the libpulse package)."; exit 1; }
done
[ "$(id -u)" != 0 ] || { echo "Run this as your normal user, not with sudo."; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- 1. upmix setting -------------------------------------------------------
CONF='# Copy stereo to all four iMac19,1 speakers (tweeters FL/FR, woofers RL/RR)
# when the CS8409 card uses its 4-channel "Analog Surround 4.0" profile.
stream.properties = {
    channelmix.upmix        = true
    channelmix.upmix-method = simple
}'
for d in client.conf.d pipewire-pulse.conf.d; do
	mkdir -p "$HOME/.config/pipewire/$d"
	printf '%s\n' "$CONF" > "$HOME/.config/pipewire/$d/50-imac-upmix.conf"
done
echo "Installed ~/.config/pipewire/{client,pipewire-pulse}.conf.d/50-imac-upmix.conf"
systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 3

# --- 2. 4-channel profile ---------------------------------------------------
CARD=$(pactl list cards short | awk '/pci-0000_00_1f\.3/ {print $2; exit}')
[ -n "$CARD" ] || { echo "Can't find the CS8409 card (pci-0000_00_1f.3)."; exit 1; }
PROFILE=$(pactl list cards | grep -oE 'output:analog-surround-40\+input:analog-stereo' | head -1)
[ -n "$PROFILE" ] || PROFILE=$(pactl list cards | grep -oE 'output:analog-surround-40[^ :]*' | head -1)
[ -n "$PROFILE" ] || { echo "No 4-channel profile found. Available profiles:"; pactl list cards | sed -n '/Profiles:/,/Active Profile/p'; exit 1; }
pactl set-card-profile "$CARD" "$PROFILE"
sleep 1
SINK=$(pactl list sinks short | awk '/pci-0000_00_1f\.3.*surround-40/ {print $2; exit}')
[ -n "$SINK" ] || { echo "The 4-channel sink did not appear."; pactl list sinks short; exit 1; }
pactl set-default-sink "$SINK"
echo "Card:    $CARD"
echo "Profile: $PROFILE"
echo "Sink:    $SINK"

# --- 3. play stereo, record the 4 channels, measure --------------------------
python3 - "$WORK/tone.wav" <<'EOF'
import math, struct, sys, wave
rate, amp = 44100, 10 ** (-30 / 20)
def tone(f, secs):
    n, fade = int(secs * rate), int(0.05 * rate)
    return [amp * min(1, i / fade, (n - i) / fade) * math.sin(2 * math.pi * f * i / rate) for i in range(n)]
sig = tone(150, 1.5) + [0.0] * int(0.4 * rate) + tone(3000, 1.5)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
w.writeframes(b''.join(struct.pack('<hh', int(v * 32767), int(v * 32767)) for v in sig)); w.close()
EOF

echo
echo "Playing a quiet STEREO test: a low hum (150 Hz), then a high tone (3 kHz)."
echo "Listen: the low hum should come clearly from the woofers."
parec -d "$SINK.monitor" --channels=4 --format=s16le --rate=44100 > "$WORK/cap.raw" &
REC=$!
sleep 0.5
( sleep 1; cat /proc/asound/card0/pcm0p/sub0/hw_params > "$WORK/hw.txt" 2>/dev/null ) &
paplay "$WORK/tone.wav"
sleep 0.5
kill $REC 2>/dev/null; wait $REC 2>/dev/null

echo
echo "Hardware stream while playing:"
grep -E 'channels|rate|format' "$WORK/hw.txt" 2>/dev/null | sed 's/^/  /' || echo "  (not captured)"

echo
python3 - "$WORK/cap.raw" <<'EOF'
import math, struct, sys
d = open(sys.argv[1], 'rb').read()
n = len(d) // 8
if n < 44100:
    print("Recording too short to measure; was anything playing?"); sys.exit()
s = struct.unpack('<%dh' % (n * 4), d[:n * 8])
names = ['FL (left tweeter)', 'FR (right tweeter)', 'RL (left woofer)', 'RR (right woofer)']
lv = []
for c in range(4):
    x = s[c::4]
    rms = math.sqrt(sum(v * v for v in x) / len(x)) / 32768
    lv.append(20 * math.log10(rms) if rms > 0 else -120)
print("Level PipeWire sent to each channel:")
for nm, l in zip(names, lv):
    print("  %-20s %7.1f dB" % (nm, l))
print()
top = max(lv)
silent = [nm for nm, l in zip(names, lv) if l < -80]
uneven = [nm for nm, l in zip(names, lv) if l >= -80 and top - l > 3]
if top < -80:
    print("RESULT: no signal at all reached the sink -- check that audio plays at all.")
elif silent:
    print("RESULT: FAIL -- silent: " + ", ".join(silent))
elif uneven:
    print("RESULT: UNEVEN -- more than 3 dB below the loudest: " + ", ".join(uneven))
else:
    print("RESULT: PASS -- all four channels within 3 dB of each other.")
EOF
