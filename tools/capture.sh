#!/bin/bash
# capture.sh -- record the CS8409 and amp state, idle and while a tone plays.
# Works under any CS8409 driver. Read-only except for turning HDA power-saving
# off until reboot (so the codec stays powered while it is measured).
#
#   sudo ./capture.sh davidjo     -> ~/capture-davidjo.txt
#   sudo ./capture.sh mine        -> ~/capture-mine.txt
set -u
LABEL=${1:-run}
CODEC=/dev/snd/hwC0D0
AMPS="0xd8 0xda 0xdc 0xde"	# 0x6c-0x6f shifted: LT RT LW RW
NAMES=(LT RT LW RW)
USER_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
OUT="$USER_HOME/capture-$LABEL.txt"
WAV=/tmp/cs8409-capture.wav

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }
for t in hda-verb aplay python3; do
	command -v $t >/dev/null || { echo "$t is needed (alsa-tools / alsa-utils / python)."; exit 1; }
done
[ -e $CODEC ] || { echo "$CODEC not found."; exit 1; }

verb()     { hda-verb $CODEC "$1" "$2" "$3" 2>/dev/null | awk '/value/ {print $3}'; }
coef_set() { verb 0x47 0x500 "$1" >/dev/null; verb 0x47 0x400 "$2" >/dev/null; }
coef_get() { verb 0x47 0x500 "$1" >/dev/null; verb 0x47 0xc00 0; }
i2c_read() {
	local sts val c
	c=$(coef_get 0x00); coef_set 0x00 "$(printf '0x%x' $(( c | 0x8 )))"
	coef_set 0x59 "$1"; coef_set 0x5e "$(printf '0x%x' $(( $2 << 8 )))"
	sleep 0.005
	sts=$(coef_get 0x5c); val=$(coef_get 0x5e)
	if (( sts & 0x10 )); then printf '%02x' $(( val & 0xff )); else printf -- '--'; fi
}

snapshot() {
	local i j a n
	echo "== $1"
	echo "-- CS8409 vendor coefs (0x47)"
	for (( i = 0; i <= 0x87; i += 8 )); do
		printf 'coef %02x:' $i
		for (( j = 0; j < 8; j++ )); do printf ' %04x' $(( $(coef_get $(( i + j ))) & 0xffff )); done
		echo
	done
	printf -- '-- GPIO (AFG 0x01): mask=%s dir=%s data=%s\n' \
		"$(verb 0x01 0xf16 0)" "$(verb 0x01 0xf17 0)" "$(verb 0x01 0xf15 0)"
	echo "-- nodes: stream-format  conv(stream/chan)  pin-ctl  power"
	for n in 0x02 0x03 0x24 0x25 0x2c; do
		printf 'node %s: fmt=%s conv=%s pinctl=%s pwr=%s\n' $n \
			"$(verb $n 0xa00 0)" "$(verb $n 0xf06 0)" "$(verb $n 0xf07 0)" "$(verb $n 0xf05 0)"
	done
	echo "-- TAS5764L registers 0x00-0x1f"
	i=0
	for a in $AMPS; do
		printf 'amp %s:' "${NAMES[$i]}"
		for (( j = 0; j < 0x20; j++ )); do printf ' %s' "$(i2c_read $a $j)"; done
		echo; i=$((i + 1))
	done
	echo
}

echo 0 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null

# 40 s, 440 Hz on all four channels at -36 dBFS (quiet; the raw device has no volume control)
python3 - "$WAV" <<'EOF'
import math, struct, sys, wave
rate, amp, f, n = 44100, 10 ** (-36 / 20), 440.0, 40 * 44100
fade = int(0.1 * rate)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(4); w.setsampwidth(4); w.setframerate(rate)
buf = bytearray()
for i in range(n):
    env = min(1.0, i / fade, (n - i) / fade)
    v = int(amp * env * math.sin(2 * math.pi * f * i / rate) * 2147483647)
    buf += struct.pack('<4i', v, v, v, v)
w.writeframes(bytes(buf)); w.close()
EOF

{
	echo "capture.sh '$LABEL' on $(date)"
	echo "kernel: $(uname -r)"
	echo "module: $(modinfo -F filename snd_hda_codec_cs8409 2>/dev/null)"
	grep -hE 'Codec:|Subsystem Id' /proc/asound/card0/codec#0
	echo
	snapshot "IDLE"
} > "$OUT"

echo "Playing a quiet tone on all four speakers while measuring (up to 40 s). Listen for it."
aplay -q -D plughw:0,0 "$WAV" &
APID=$!
sleep 3
{
	snapshot "PLAYING"
	echo "-- hw_params while playing"
	cat /proc/asound/card0/pcm0p/sub0/hw_params 2>/dev/null
	echo
	echo "-- /proc/asound/card0/codec#0 while playing"
	cat /proc/asound/card0/codec#0
} >> "$OUT"
if kill -0 $APID 2>/dev/null; then
	echo "tone was still playing when measuring finished (good)" >> "$OUT"
	kill $APID 2>/dev/null; wait $APID 2>/dev/null
else
	wait $APID; echo "WARNING: aplay ended early, status $?" >> "$OUT"
fi

chown "${SUDO_USER:-root}": "$OUT" 2>/dev/null
echo "Saved: $OUT"
