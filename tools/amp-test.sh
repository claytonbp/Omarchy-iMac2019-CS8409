#!/bin/bash
# amp-test.sh -- raise the TAS5764L amp volume, switch on the CS8409 ports,
# and play the quiet per-channel test tone. No rebuild, no reboot; a reboot
# undoes everything.
#
#   sudo ./amp-test.sh            amp volume 0x9f (about -24 dB)
#   sudo ./amp-test.sh 0xaf       about -16 dB
#   sudo ./amp-test.sh 0xbf       about  -8 dB (don't go above this yet)
#
# Amp register 0x04 is the volume: 0xcf = 0 dB, 0.5 dB per step (meaning
# taken from the macOS-trace notes in davidjo/snd_hda_macbookpro). The
# firmware leaves it at 0x5c, about -57 dB. Only that register is written.
set -u
CODEC=/dev/snd/hwC0D0
VOL=${1:-0x9f}
AMPS="0xd8 0xda 0xdc 0xde"	# 0x6c-0x6f shifted: LT RT LW RW
NAMES=(LT RT LW RW)

[ "$(id -u)" = 0 ] || { echo "Run with sudo."; exit 1; }
command -v hda-verb >/dev/null || { echo "hda-verb is needed: sudo pacman -S alsa-tools"; exit 1; }
[ -e $CODEC ] || { echo "$CODEC not found."; exit 1; }
if (( VOL > 0xbf )); then echo "Volume capped at 0xbf for now."; VOL=0xbf; fi

verb()     { hda-verb $CODEC 0x47 "$1" "$2" 2>/dev/null | awk '/value/ {print $3}'; }
coef_set() { verb 0x500 "$1" >/dev/null; verb 0x400 "$2" >/dev/null; }
coef_get() { verb 0x500 "$1" >/dev/null; verb 0xc00 0; }
i2c_on()   { local c; c=$(coef_get 0x00); coef_set 0x00 "$(printf '0x%x' $(( c | 0x8 )))"; }
i2c_read() {	# addr8 reg -> prints value, or -- if no ACK
	local sts val
	i2c_on; coef_set 0x59 "$1"; coef_set 0x5e "$(printf '0x%x' $(( $2 << 8 )))"
	sleep 0.01
	sts=$(coef_get 0x5c); val=$(coef_get 0x5e)
	if (( sts & 0x10 )); then printf '%02x' $(( val & 0xff )); else printf -- '--'; fi
}
i2c_write() {	# addr8 reg val
	i2c_on; coef_set 0x59 "$1"; coef_set 0x5d "$(printf '0x%x' $(( ($2 << 8) | $3 )))"
	sleep 0.01
}
show_amps() {
	local i=0 a r
	echo "      reg: 01 02 03 04 05 06 08"
	for a in $AMPS; do
		printf '  amp %s: ' "${NAMES[$i]}"
		for r in 0x01 0x02 0x03 0x04 0x05 0x06 0x08; do printf '%s ' "$(i2c_read $a $r)"; done
		echo; i=$((i + 1))
	done
}

echo 0 > /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null

echo "Amps before:"; show_amps
for a in $AMPS; do i2c_write $a 0x04 $(( VOL )); done
echo; echo "Amp volume (reg 04) set to $VOL. Amps after:"; show_amps

coef_set 0x01 0x62
echo; echo "CS8409 DEV_CFG2 (ports) set to 0x62, reads back: $(coef_get 0x01)"
echo

exec "$(dirname "$0")/tone-test.sh"
