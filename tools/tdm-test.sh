#!/bin/bash
# tdm-test.sh -- replay the macOS playback set-up for the iMac speakers, then
# play the quiet per-channel test tone. No rebuild, no reboot; a reboot undoes
# everything.
#
#   sudo ./tdm-test.sh            amp volume 0x9f (about -24 dB)
#   sudo ./tdm-test.sh 0xaf       about -16 dB (cap 0xbf)
#
# The register sequence is the one macOS's AppleHDATDMBusManagerCS8409 runs
# before playback, as recorded in the trace notes of davidjo/snd_hda_macbookpro
# (GPL-2.0): setSampleRate, setupTDMPath and configureTDMUR for amps 1+2 and
# 3+4, the converter sync, then the TAS5764L set-up. Values only; the
# analog gain (amp reg 06) is left at the firmware's lower 0x51.
set -u
CODEC=/dev/snd/hwC0D0
VOL=${1:-0x9f}
AMPS="0xd8 0xda 0xdc 0xde"	# 0x6c-0x6f shifted: LT RT LW RW
NAMES=(LT RT LW RW)

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }
command -v hda-verb >/dev/null || { echo "hda-verb is needed: sudo pacman -S alsa-tools"; exit 1; }
[ -e $CODEC ] || { echo "$CODEC not found."; exit 1; }
if (( VOL > 0xbf )); then echo "Volume capped at 0xbf for now."; VOL=0xbf; fi

verb()     { hda-verb $CODEC "$1" "$2" "$3" 2>/dev/null | awk '/value/ {print $3}'; }
coef_set() { verb 0x47 0x500 "$1" >/dev/null; verb 0x47 0x400 "$2" >/dev/null; }
coef_get() { verb 0x47 0x500 "$1" >/dev/null; verb 0x47 0xc00 0; }
coef_or()  { local c; c=$(coef_get "$1"); coef_set "$1" "$(printf '0x%x' $(( c | $2 )))"; }
i2c_on()   { coef_or 0x00 0x8; }
i2c_read() {
	local sts val
	i2c_on; coef_set 0x59 "$1"; coef_set 0x5e "$(printf '0x%x' $(( $2 << 8 )))"
	sleep 0.01
	sts=$(coef_get 0x5c); val=$(coef_get 0x5e)
	if (( sts & 0x10 )); then printf '%02x' $(( val & 0xff )); else printf -- '--'; fi
}
i2c_write() {
	i2c_on; coef_set 0x59 "$1"; coef_set 0x5d "$(printf '0x%x' $(( ($2 << 8) | $3 )))"
	sleep 0.01
}
show_coefs() {
	local i
	printf '  CS8409 coef:'
	for i in 0x00 0x01 0x02 0x03 0x04 0x05 0x17 0x19 0x1a 0x1b 0x1c 0x6b 0x71 0x82; do
		printf ' %02x=%04x' $(( i )) $(( $(coef_get $i) ))
	done
	echo
}
show_amps() {
	local i=0 a r
	echo "      reg: 01 02 03 04 05 06 08 13"
	for a in $AMPS; do
		printf '  amp %s: ' "${NAMES[$i]}"
		for r in 0x01 0x02 0x03 0x04 0x05 0x06 0x08 0x13; do printf '%s ' "$(i2c_read $a $r)"; done
		echo; i=$((i + 1))
	done
}

echo 0 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null

echo "Before:"; show_coefs; show_amps

# setSampleRate (masked writes: new = (old & ~mask) | value)
c=$(coef_get 0x01); coef_set 0x01 "$(printf '0x%x' $(( (c & ~0x0380) | 0x0200 )))"
c=$(coef_get 0x05); coef_set 0x05 "$(printf '0x%x' $(( (c & ~0x0007) | 0x0001 )))"
c=$(coef_get 0x04); coef_set 0x04 "$(printf '0x%x' $(( (c & ~0x01ff) | 0x08ff )))"

# setupTDMPath, amps 1+2: ASP1 slot A = bits 0 and 32, 24-bit
coef_set 0x19 0x0800
coef_set 0x1a 0x0820
c0=$(coef_get 0x00); coef_set 0x00 "$(printf '0x%x' $(( c0 | 0x2000 )))"	# PLL2 on briefly ...
coef_set 0x04 0x08ff
coef_set 0x00 "$c0"								# ... and back
coef_set 0x03 0x8000
coef_set 0x05 0x0001
coef_or  0x82 0x5400
coef_set 0x02 0x0280
coef_or  0x01 0x0020
# configureTDMUR
coef_set 0x6b 0x001f
coef_or  0x71 0x400f
verb 0x47 0x7f0 0xb6 >/dev/null
verb 0x24 0x707 0x40 >/dev/null		# pin 0x24 output on

# setupTDMPath, amps 3+4: ASP1 slot B = bits 64 and 96
coef_set 0x1b 0x0840
coef_set 0x1c 0x0860
coef_set 0x6b 0x001f
coef_or  0x71 0x400f
verb 0x47 0x7f0 0xb6 >/dev/null
verb 0x25 0x707 0x40 >/dev/null		# pin 0x25 output on

# converter sync
verb 0x47 0x703 0x01 >/dev/null		# vendor processing on
coef_set 0x17 0x0001
coef_set 0x17 0x0003

# TAS5764L set-up as macOS does it (gain reg 06 left as is)
for a in $AMPS; do
	i2c_write $a 0x02 0x44
	i2c_write $a 0x08 0x18		# clear fault/clock-error flags
	i2c_write $a 0x04 $(( VOL ))
	i2c_write $a 0x13 0x00
	i2c_write $a 0x02 0x44
	i2c_write $a 0x01 0xfd		# awake, speaker amp on
done

echo; echo "After (amp volume $VOL):"; show_coefs; show_amps
echo

exec "$(dirname "$0")/tone-test.sh"
