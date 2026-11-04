#!/bin/bash
# switches.sh -- show or change the live speaker-start switches.
#   ./switches.sh                         show current values
#   sudo ./switches.sh apple_afg_cycle=0  change one (or several) until reboot
P=/sys/module/snd_hda_codec_cs8409/parameters
for kv in "$@"; do
	k=${kv%%=*}; v=${kv#*=}
	[ -w "$P/$k" ] || { echo "Can't set $k (run with sudo?)"; exit 1; }
	echo "$v" > "$P/$k"
done
for k in apple_spk_order apple_afg_cycle apple_hp_off apple_gpio_inputs apple_amp_volume; do
	printf '%-18s %s\n' "$k" "$(cat $P/$k 2>/dev/null)"
done
