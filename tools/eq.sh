#!/bin/bash
# eq.sh -- bass, treble and loudness for the iMac19,1 speakers (a PipeWire equaliser).
# Run as your normal user (not sudo), after INSTALL.md step 7. Needs: sudo pacman -S swh-plugins
#
#   bash tools/eq.sh              show the current setting
#   bash tools/eq.sh 4 2 6        bass +4 dB, treble +2 dB, loudness +6 dB
#   bash tools/eq.sh 4 2          change bass and treble, keep the loudness
#   bash tools/eq.sh 0 0 0        flat: as without the equaliser (1 dB quieter)
#   bash tools/eq.sh off          remove the equaliser
# Changes apply at once and are kept after a reboot.
#
# It adds a sound output called "iMac Speakers (EQ)" in front of the speakers and makes it
# the default:
#   bass     -> a low shelf (below 150 Hz) on the woofers only
#   treble   -> a high shelf (above 4 kHz) on the tweeters only
#   loudness -> raises the level, and a look-ahead limiter on each speaker pair turns the
#               loudest peaks down smoothly so they stay below full scale (no clipping).
#               This is how small speakers are made loud: the iMac's chip has no volume
#               control of its own, so PipeWire's 100% is already the loudest clean signal.
# Each bass/treble boost is made by turning the rest of that speaker down by the same amount.
# The tweeters also get a gentle cut below 80 Hz and the woofers below 40 Hz: deep bass they
# can't play anyway, which would only use up their movement.
# Ranges: bass and treble -12 to +8 dB, loudness 0 to 12 dB.
set -euo pipefail

HW=${IMAC_EQ_TARGET:-alsa_output.pci-0000_00_1f.3.analog-surround-40}
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/60-imac-eq.conf
EQ=imac_eq
GRAPH=2               # layout of the filter graph below; a change needs a PipeWire restart
LIMIT=-1.0            # limiter ceiling, dB below full scale
RELEASE=0.3           # limiter release time, s
LIMPLUG=fast_lookahead_limiter_1913   # from swh-plugins

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" != 0 ] || die "run as your normal user, without sudo"
for c in pw-cli pactl; do command -v $c >/dev/null || die "$c is missing (sudo pacman -S pipewire libpulse)"; done

restart_pw() { systemctl --user restart pipewire pipewire-pulse wireplumber; }
sink_exists() { pactl list short sinks | awk '{print $2}' | grep -qx "$1"; }
wait_sink() { for _ in $(seq 40); do sink_exists "$1" && return 0; sleep 0.25; done; return 1; }
vol_pct() { pactl get-sink-volume "$1" | grep -o '[0-9]*%' | head -1 | tr -d %; }
conf_val() { [ -f "$CONF" ] && sed -n "s/^# $1: //p" "$CONF" | head -1; }

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

if [ $# -eq 0 ]; then
	echo "Equaliser: $(current)"
	show_vols
	echo "Change it with: bash tools/eq.sh BASS TREBLE [LOUDNESS]   (e.g. 4 2 6), or: bash tools/eq.sh off"
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
	exit 0
fi

usage="usage: bash tools/eq.sh BASS TREBLE [LOUDNESS]   (dB, e.g. 4 2 6), or: bash tools/eq.sh off"
[ $# -eq 2 ] || [ $# -eq 3 ] || die "$usage"
num='^[+-]?[0-9]+([.][0-9]+)?$'
L_IN=${3:-$(conf_val loudness || true)}; L_IN=${L_IN:-0}
[[ $1 =~ $num && $2 =~ $num && $L_IN =~ $num ]] || die "BASS, TREBLE and LOUDNESS must be numbers in dB, e.g. 4 2 6"
B=$(awk -v x="$1" 'BEGIN{printf "%.1f", x}'); T=$(awk -v x="$2" 'BEGIN{printf "%.1f", x}')
L=$(awk -v x="$L_IN" 'BEGIN{printf "%.1f", x}')
awk -v b="$B" -v t="$T" 'BEGIN{exit !(b>=-12 && b<=8 && t>=-12 && t<=8)}' \
	|| die "bass and treble must each be between -12 and +8 dB"
awk -v l="$L" 'BEGIN{exit !(l>=0 && l<=12)}' || die "loudness must be between 0 and 12 dB"

found=
for d in ${LADSPA_PATH:+${LADSPA_PATH//:/ }} /usr/lib/ladspa /usr/lib64/ladspa /usr/local/lib/ladspa; do
	[ -f "$d/$LIMPLUG.so" ] && found=1
done
[ -n "$found" ] || die "the limiter plugin isn't installed. Run: sudo pacman -S swh-plugins
       then run this again."

# Level of each speaker pair. Woofers sit 3 dB below the tweeters, as with the plain upmix
# (INSTALL.md step 7). 1 dB of headroom covers the small rise the low-cut filters add, and a
# bass/treble boost lowers the pair's level by as much as it adds. Loudness is added after
# that, in the limiters, which keep every peak at or below $LIMIT dB.
TW=$(awk -v t="$T" 'BEGIN{printf "%.1f", -1 - (t>0 ? t : 0)}')
WF=$(awk -v b="$B" 'BEGIN{printf "%.1f", -4 - (b>3 ? b-3 : 0)}')

sink_exists "$HW" || sink_exists "$EQ" || die "the 4-channel speaker output $HW isn't there.
       Do INSTALL.md step 7 first (the analog-surround-40 profile), then run this again."

old_graph=$(conf_val graph || true)
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# iMac19,1 speakers: bass, treble and loudness (written by tools/eq.sh; change it with that script).
# setting: bass $B dB, treble $T dB, loudness $L dB
# loudness: $L
# graph: $GRAPH
# Tweeters: high-pass 80 Hz, high shelf 4 kHz (treble), level $TW dB, limiter (gain $L dB, ceiling $LIMIT dB).
# Woofers:  high-pass 40 Hz, low shelf 150 Hz (bass),  level $WF dB, limiter (gain $L dB, ceiling $LIMIT dB).
context.modules = [
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "iMac Speakers (EQ)"
      media.name       = "iMac Speakers (EQ)"
      filter.graph = {
        nodes = [
          { type = builtin name = inL     label = copy }
          { type = builtin name = inR     label = copy }
          { type = builtin name = tw_hp_L label = bq_highpass  control = { "Freq" = 80.0 "Q" = 0.707 } }
          { type = builtin name = tw_hp_R label = bq_highpass  control = { "Freq" = 80.0 "Q" = 0.707 } }
          { type = builtin name = treb_L  label = bq_highshelf control = { "Freq" = 4000.0 "Q" = 0.707 "Gain" = $T } }
          { type = builtin name = treb_R  label = bq_highshelf control = { "Freq" = 4000.0 "Q" = 0.707 "Gain" = $T } }
          { type = builtin name = tw_lv_L label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = $TW } }
          { type = builtin name = tw_lv_R label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = $TW } }
          { type = ladspa  name = tw_lim  plugin = $LIMPLUG label = fastLookaheadLimiter
            control = { "Input gain (dB)" = $L "Limit (dB)" = $LIMIT "Release time (s)" = $RELEASE } }
          { type = builtin name = wf_hp_L label = bq_highpass  control = { "Freq" = 40.0 "Q" = 0.707 } }
          { type = builtin name = wf_hp_R label = bq_highpass  control = { "Freq" = 40.0 "Q" = 0.707 } }
          { type = builtin name = bass_L  label = bq_lowshelf  control = { "Freq" = 150.0 "Q" = 0.707 "Gain" = $B } }
          { type = builtin name = bass_R  label = bq_lowshelf  control = { "Freq" = 150.0 "Q" = 0.707 "Gain" = $B } }
          { type = builtin name = wf_lv_L label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = $WF } }
          { type = builtin name = wf_lv_R label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = $WF } }
          { type = ladspa  name = wf_lim  plugin = $LIMPLUG label = fastLookaheadLimiter
            control = { "Input gain (dB)" = $L "Limit (dB)" = $LIMIT "Release time (s)" = $RELEASE } }
        ]
        links = [
          { output = "inL:Out"     input = "tw_hp_L:In" }
          { output = "tw_hp_L:Out" input = "treb_L:In" }
          { output = "treb_L:Out"  input = "tw_lv_L:In" }
          { output = "tw_lv_L:Out" input = "tw_lim:Input 1" }
          { output = "inR:Out"     input = "tw_hp_R:In" }
          { output = "tw_hp_R:Out" input = "treb_R:In" }
          { output = "treb_R:Out"  input = "tw_lv_R:In" }
          { output = "tw_lv_R:Out" input = "tw_lim:Input 2" }
          { output = "inL:Out"     input = "wf_hp_L:In" }
          { output = "wf_hp_L:Out" input = "bass_L:In" }
          { output = "bass_L:Out"  input = "wf_lv_L:In" }
          { output = "wf_lv_L:Out" input = "wf_lim:Input 1" }
          { output = "inR:Out"     input = "wf_hp_R:In" }
          { output = "wf_hp_R:Out" input = "bass_R:In" }
          { output = "bass_R:Out"  input = "wf_lv_R:In" }
          { output = "wf_lv_R:Out" input = "wf_lim:Input 2" }
        ]
        inputs  = [ "inL:In" "inR:In" ]
        outputs = [ "tw_lim:Output 1" "tw_lim:Output 2" "wf_lim:Output 1" "wf_lim:Output 2" ]
      }
      capture.props = {
        node.name      = "$EQ"
        media.class    = Audio/Sink
        audio.position = [ FL FR ]
        # WirePlumber saves and restores this output's volume; if that saved value is ever
        # lost, start at 50% (0.125 = 0.5 cubed), never at full volume.
        state.default-volume = 0.125
      }
      playback.props = {
        node.name         = "$EQ.output"
        audio.position    = [ FL FR RL RR ]
        target.object     = "$HW"
        stream.dont-remix = true
        node.passive      = true
      }
    }
  }
]
EOF

if sink_exists "$EQ" && [ "$old_graph" = "$GRAPH" ]; then
	# Already running with this layout: change the controls live, no restart needed.
	id=$(pw-cli ls Node | awk -v n="node.name = \"$EQ\"" '/^\tid /{gsub(",","",$2); id=$2} index($0,n){print id; exit}')
	[ -n "$id" ] || die "can't find the equaliser node; run: systemctl --user restart pipewire pipewire-pulse wireplumber"
	pw-cli set-param "$id" Props "{ params = [
		\"treb_L:Gain\" $T \"treb_R:Gain\" $T \"tw_lv_L:Gain\" $TW \"tw_lv_R:Gain\" $TW
		\"bass_L:Gain\" $B \"bass_R:Gain\" $B \"wf_lv_L:Gain\" $WF \"wf_lv_R:Gain\" $WF
		\"tw_lim:Input gain (dB)\" $L \"wf_lim:Input gain (dB)\" $L ] }" >/dev/null
	[ "$(vol_pct "$HW")" = 100 ] || speakers_full
	echo "Equaliser: bass $B dB, treble $T dB, loudness $L dB (applied now; kept after a reboot)."
else
	# First time, or an older layout: (re)start it. Sound stops for a moment.
	if sink_exists "$EQ"; then v=$(vol_pct "$EQ"); else v=$(vol_pct "$HW"); fi
	restart_pw
	wait_sink "$EQ" || die "the equaliser didn't start. Check: journalctl --user -u pipewire -b | tail -20
       To undo: rm $CONF; systemctl --user restart pipewire pipewire-pulse wireplumber"
	wait_sink "$HW" || true
	pactl set-default-sink "$EQ"
	pactl set-sink-volume "$EQ" "$v%"     # your volume control now sets this one
	sleep 2; speakers_full                # and the speakers pass it through at full level
	echo "Equaliser on: bass $B dB, treble $T dB, loudness $L dB. Default output: \"iMac Speakers (EQ)\" (volume $v%)."
	echo "Change it any time with: bash tools/eq.sh BASS TREBLE LOUDNESS"
fi
