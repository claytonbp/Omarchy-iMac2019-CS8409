#!/bin/bash
# eq.sh -- sound settings for the iMac19,1 speakers (a PipeWire equaliser).
# Run as your normal user (not sudo), after INSTALL.md step 7. Needs: sudo pacman -S swh-plugins
#
#   bash tools/eq.sh apple FILE   use Apple's own speaker tuning, read from a copy of macOS's
#                                 layout16.xml.zlib (see INSTALL.md step 8); best sound
#   bash tools/eq.sh apple off    back to the simple equaliser
#   bash tools/eq.sh 4 2 6        bass +4 dB, treble +2 dB, loudness +6 dB (on top of either)
#   bash tools/eq.sh 4 2          change bass and treble, keep the loudness
#   bash tools/eq.sh              show the current setting
#   bash tools/eq.sh off          remove the equaliser
# Changes apply at once and are kept after a reboot.
#
# It adds a sound output called "iMac Speakers (EQ)" in front of the speakers and makes it
# the default.
#   Apple tuning -> Apple's EQ, crossover (tweeters above ~3 kHz, woofers below ~1.4 kHz),
#                   levels and tweeter delay for these speakers, from macOS. Apple's file
#                   stays on this machine (~/.config/pipewire/imac-apple-tuning.json).
#   bass     -> a low shelf (below 150 Hz) on the woofers only
#   treble   -> a high shelf (above 4 kHz) on the tweeters only
#   loudness -> raises the level, and a look-ahead limiter on each speaker pair turns the
#               loudest peaks down smoothly so they stay below full scale (no clipping).
#               The iMac's chip has no volume control of its own, so PipeWire's 100% is
#               already the loudest clean signal; macOS gets its loudness the same way.
# Ranges: bass and treble -12 to +8 dB, loudness 0 to 12 dB.
set -euo pipefail

HW=${IMAC_EQ_TARGET:-alsa_output.pci-0000_00_1f.3.analog-surround-40}
PWDIR=${XDG_CONFIG_HOME:-$HOME/.config}/pipewire
CONF=$PWDIR/pipewire.conf.d/60-imac-eq.conf
TUNING=$PWDIR/imac-apple-tuning.json
EQ=imac_eq
GEN="$(cd "$(dirname "$0")" && pwd)/eqgen.py"
LIMPLUG=fast_lookahead_limiter_1913   # from swh-plugins

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" != 0 ] || die "run as your normal user, without sudo"
for c in pw-cli pactl python3; do command -v $c >/dev/null || die "$c is missing (sudo pacman -S pipewire libpulse python)"; done
[ -f "$GEN" ] || die "eqgen.py is missing; it belongs next to eq.sh in tools/"

restart_pw() { systemctl --user restart pipewire pipewire-pulse wireplumber; }
sink_exists() { pactl list short sinks | awk '{print $2}' | grep -qx "$1"; }
wait_sink() { for _ in $(seq 40); do sink_exists "$1" && return 0; sleep 0.25; done; return 1; }
vol_pct() { pactl get-sink-volume "$1" | grep -o '[0-9]*%' | head -1 | tr -d %; }
conf_val() { [ -f "$CONF" ] && sed -n "s/^# $1: //p" "$CONF" | head -1; }
gen() { python3 -I "$GEN" "$@"; }
tuning_arg() { [ -f "$TUNING" ] && echo "$TUNING" || true; }

current() { [ -f "$CONF" ] && conf_val setting || echo "off (no equaliser)"; }
show_vols() {
	echo "Default output: $(pactl get-default-sink)"
	if sink_exists "$EQ"; then
		echo "  iMac Speakers (EQ) volume: $(vol_pct "$EQ")%   (your volume control)"
		sink_exists "$HW" && echo "  speakers' own volume:      $(vol_pct "$HW")%   (should be 100% while the equaliser is on)"
	else
		sink_exists "$HW" && echo "  speakers' volume: $(vol_pct "$HW")%"
	fi
	return 0
}
# WirePlumber restores the speakers' saved volume when they reappear after a restart, which
# can land after our change; so set it, wait, and set it again until it holds.
speakers_full() {
	for _ in 1 2 3 4 5 6; do
		pactl set-sink-volume "$HW" 100%; sleep 1
		[ "$(vol_pct "$HW")" = 100 ] && return 0
	done
	echo "WARNING: the speakers' own volume won't stay at 100%; check with: bash tools/eq.sh" >&2
}
# the current bass/treble/loudness, from the config if there is one
cur_btl() {
	local s; s=$(conf_val setting || true)
	B=$(sed -n 's/.*bass \([-0-9.]*\) dB.*/\1/p' <<<"$s"); T=$(sed -n 's/.*treble \([-0-9.]*\) dB.*/\1/p' <<<"$s")
	L=$(conf_val loudness || true)
	B=${B:-$1}; T=${T:-$2}; L=${L:-$3}
}

if [ $# -eq 0 ]; then
	echo "Equaliser: $(current)"
	show_vols
	echo "Change it with: bash tools/eq.sh BASS TREBLE [LOUDNESS]   (e.g. 4 2 6), or: bash tools/eq.sh off"
	[ -f "$TUNING" ] || echo "Apple's own tuning: bash tools/eq.sh apple /path/to/layout16.xml.zlib   (INSTALL.md step 8)"
	exit 0
fi

if [ "$1" = off ]; then
	[ -f "$CONF" ] || { echo "The equaliser is already off."; exit 0; }
	v=$(vol_pct "$EQ" 2>/dev/null || true)
	rm -f "$CONF"
	restart_pw
	wait_sink "$HW" || die "the speaker output $HW did not come back; run: systemctl --user restart pipewire pipewire-pulse wireplumber"
	pactl set-default-sink "$HW"
	[ -n "$v" ] && pactl set-sink-volume "$HW" "$v%"
	echo "Equaliser removed. The speakers play as before (volume ${v:-unchanged}%)."
	[ -f "$TUNING" ] && echo "(Apple's tuning is still saved; 'bash tools/eq.sh 0 0 8' would bring it back.)"
	exit 0
fi

num='^[+-]?[0-9]+([.][0-9]+)?$'
if [ "$1" = apple ]; then
	[ $# -eq 2 ] || die "usage: bash tools/eq.sh apple /path/to/layout16.xml.zlib   or: bash tools/eq.sh apple off"
	if [ "$2" = off ]; then
		[ -f "$TUNING" ] || { echo "Apple's tuning isn't in use."; exit 0; }
		rm -f "$TUNING"; echo "Apple's tuning removed; back to the simple equaliser."
		cur_btl 0 0 0
	else
		[ -f "$2" ] || die "no such file: $2"
		mkdir -p "$PWDIR"
		gen import "$2" "$TUNING.new" || { rm -f "$TUNING.new"; exit 1; }
		chmod 600 "$TUNING.new"; mv "$TUNING.new" "$TUNING"
		# Apple's chain sits about 7 dB below full scale (macOS adds it back with a compressor),
		# so start with bass and treble flat and loudness 8, or keep the loudness already set.
		B=0; T=0; L=$(conf_val loudness || true); L=${L:-8}
		awk -v l="$L" 'BEGIN{exit !(l<6)}' && L=8.0
	fi
else
	[ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: bash tools/eq.sh BASS TREBLE [LOUDNESS]   (dB, e.g. 4 2 6), or: bash tools/eq.sh off"
	B=$1; T=$2; L=${3:-$(conf_val loudness || true)}; L=${L:-0}
fi
[[ $B =~ $num && $T =~ $num && $L =~ $num ]] || die "BASS, TREBLE and LOUDNESS must be numbers in dB, e.g. 4 2 6"
B=$(awk -v x="$B" 'BEGIN{printf "%.1f", x}'); T=$(awk -v x="$T" 'BEGIN{printf "%.1f", x}'); L=$(awk -v x="$L" 'BEGIN{printf "%.1f", x}')
awk -v b="$B" -v t="$T" 'BEGIN{exit !(b>=-12 && b<=8 && t>=-12 && t<=8)}' || die "bass and treble must each be between -12 and +8 dB"
awk -v l="$L" 'BEGIN{exit !(l>=0 && l<=12)}' || die "loudness must be between 0 and 12 dB"

found=
for d in ${LADSPA_PATH:+${LADSPA_PATH//:/ }} /usr/lib/ladspa /usr/lib64/ladspa /usr/local/lib/ladspa; do
	[ -f "$d/$LIMPLUG.so" ] && found=1
done
[ -n "$found" ] || die "the limiter plugin isn't installed. Run: sudo pacman -S swh-plugins
       then run this again."
sink_exists "$HW" || sink_exists "$EQ" || die "the 4-channel speaker output $HW isn't there.
       Do INSTALL.md step 7 first (the analog-surround-40 profile), then run this again."

TU=$(tuning_arg)
old_graph=$(conf_val graph || true)
new_graph=$(gen graph $TU)
mkdir -p "$(dirname "$CONF")"
gen conf "$B" "$T" "$L" "$HW" "$EQ" $TU > "$CONF.new" && mv "$CONF.new" "$CONF"
mode=$( [ -n "$TU" ] && echo "Apple's tuning + " || true )

if sink_exists "$EQ" && [ "$old_graph" = "$new_graph" ]; then
	# Already running with this layout: change the controls live, no restart needed.
	id=$(pw-cli ls Node | awk -v n="node.name = \"$EQ\"" '/^\tid /{gsub(",","",$2); id=$2} index($0,n){print id; exit}')
	[ -n "$id" ] || die "can't find the equaliser node; run: systemctl --user restart pipewire pipewire-pulse wireplumber"
	pw-cli set-param "$id" Props "$(gen params "$B" "$T" "$L" $TU)" >/dev/null
	[ "$(vol_pct "$HW")" = 100 ] || speakers_full
	echo "Equaliser: ${mode}bass $B dB, treble $T dB, loudness $L dB (applied now; kept after a reboot)."
else
	# First time, or a different layout: (re)start it. Sound stops for a moment.
	if sink_exists "$EQ"; then v=$(vol_pct "$EQ"); else v=$(vol_pct "$HW"); fi
	restart_pw
	wait_sink "$EQ" || die "the equaliser didn't start. Check: journalctl --user -u pipewire -b | tail -20
       To undo: bash tools/eq.sh off"
	wait_sink "$HW" || true
	pactl set-default-sink "$EQ"
	pactl set-sink-volume "$EQ" "$v%"     # your volume control now sets this one
	sleep 2; speakers_full                # and the speakers pass it through at full level
	echo "Equaliser on: ${mode}bass $B dB, treble $T dB, loudness $L dB. Default output: \"iMac Speakers (EQ)\" (volume $v%)."
	echo "Change it any time with: bash tools/eq.sh BASS TREBLE LOUDNESS"
fi
