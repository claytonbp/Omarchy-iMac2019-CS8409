#!/bin/bash
# eq.sh -- bass and treble for the iMac19,1 speakers (a PipeWire equaliser).
# Run as your normal user (not sudo), after INSTALL.md step 7.
#
#   bash tools/eq.sh            show the current setting
#   bash tools/eq.sh 4 2        bass +4 dB, treble +2 dB: applied at once, kept after a reboot
#   bash tools/eq.sh 0 0        flat: sounds the same as without the equaliser
#   bash tools/eq.sh off        remove the equaliser
#
# It adds a sound output called "iMac Speakers (EQ)" in front of the speakers and makes it
# the default:
#   bass   -> a low shelf (below 150 Hz) on the woofers only
#   treble -> a high shelf (above 4 kHz) on the tweeters only
# Each boost is made by turning the rest of that speaker down by the same amount, so a boost
# can't push the signal past full scale (no clipping). At 0 0 it sounds as before, 1 dB quieter. The tweeters also get a gentle
# cut below 80 Hz and the woofers below 40 Hz: deep bass they can't play anyway, which
# would only use up their movement.
# Range: bass and treble -12 to +8 dB. Start small; +3 to +5 is usually plenty.
set -euo pipefail

HW=${IMAC_EQ_TARGET:-alsa_output.pci-0000_00_1f.3.analog-surround-40}
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/60-imac-eq.conf
EQ=imac_eq

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" != 0 ] || die "run as your normal user, without sudo"
for c in pw-cli pactl; do command -v $c >/dev/null || die "$c is missing (sudo pacman -S pipewire libpulse)"; done

restart_pw() { systemctl --user restart pipewire pipewire-pulse wireplumber; }
sink_exists() { pactl list short sinks | awk '{print $2}' | grep -qx "$1"; }
wait_sink() { for _ in $(seq 40); do sink_exists "$1" && return 0; sleep 0.25; done; return 1; }
vol_pct() { pactl get-sink-volume "$1" | grep -o '[0-9]*%' | head -1 | tr -d %; }

current() { [ -f "$CONF" ] && sed -n 's/^# setting: //p' "$CONF" || echo "off (no equaliser)"; }

if [ $# -eq 0 ]; then
	echo "Equaliser: $(current)"
	echo "Change it with: bash tools/eq.sh BASS TREBLE   (e.g. 4 2), or: bash tools/eq.sh off"
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

[ $# -eq 2 ] || die "usage: bash tools/eq.sh BASS TREBLE   (dB, e.g. 4 2), or: bash tools/eq.sh off"
num='^[+-]?[0-9]+([.][0-9]+)?$'
[[ $1 =~ $num && $2 =~ $num ]] || die "BASS and TREBLE must be numbers in dB, e.g. 4 2 or -2 3.5"
B=$(awk -v x="$1" 'BEGIN{printf "%.1f", x}'); T=$(awk -v x="$2" 'BEGIN{printf "%.1f", x}')
awk -v b="$B" -v t="$T" 'BEGIN{exit !(b>=-12 && b<=8 && t>=-12 && t<=8)}' \
	|| die "bass and treble must each be between -12 and +8 dB"

# Level of each speaker pair. Woofers sit 3 dB below the tweeters, as with the plain upmix
# (INSTALL.md step 7). 1 dB of headroom covers the small rise the low-cut filters add, and a
# boost lowers the pair's level just enough that the boosted part still stays below full
# scale (measured: every setting peaks at or below 0 dB).
TW=$(awk -v t="$T" 'BEGIN{printf "%.1f", -1 - (t>0 ? t : 0)}')
WF=$(awk -v b="$B" 'BEGIN{printf "%.1f", -4 - (b>3 ? b-3 : 0)}')

sink_exists "$HW" || sink_exists "$EQ" || die "the 4-channel speaker output $HW isn't there.
       Do INSTALL.md step 7 first (the analog-surround-40 profile), then run this again."

mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# iMac19,1 speakers: bass and treble (written by tools/eq.sh; change it with that script).
# setting: bass $B dB, treble $T dB
# Tweeters: high-pass 80 Hz, high shelf 4 kHz (treble), level $TW dB.
# Woofers:  high-pass 40 Hz, low shelf 150 Hz (bass),  level $WF dB.
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
          { type = builtin name = wf_hp_L label = bq_highpass  control = { "Freq" = 40.0 "Q" = 0.707 } }
          { type = builtin name = wf_hp_R label = bq_highpass  control = { "Freq" = 40.0 "Q" = 0.707 } }
          { type = builtin name = bass_L  label = bq_lowshelf  control = { "Freq" = 150.0 "Q" = 0.707 "Gain" = $B } }
          { type = builtin name = bass_R  label = bq_lowshelf  control = { "Freq" = 150.0 "Q" = 0.707 "Gain" = $B } }
          { type = builtin name = wf_lv_L label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = $WF } }
          { type = builtin name = wf_lv_R label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = $WF } }
        ]
        links = [
          { output = "inL:Out"     input = "tw_hp_L:In" }
          { output = "tw_hp_L:Out" input = "treb_L:In" }
          { output = "treb_L:Out"  input = "tw_lv_L:In" }
          { output = "inR:Out"     input = "tw_hp_R:In" }
          { output = "tw_hp_R:Out" input = "treb_R:In" }
          { output = "treb_R:Out"  input = "tw_lv_R:In" }
          { output = "inL:Out"     input = "wf_hp_L:In" }
          { output = "wf_hp_L:Out" input = "bass_L:In" }
          { output = "bass_L:Out"  input = "wf_lv_L:In" }
          { output = "inR:Out"     input = "wf_hp_R:In" }
          { output = "wf_hp_R:Out" input = "bass_R:In" }
          { output = "bass_R:Out"  input = "wf_lv_R:In" }
        ]
        inputs  = [ "inL:In" "inR:In" ]
        outputs = [ "tw_lv_L:Out" "tw_lv_R:Out" "wf_lv_L:Out" "wf_lv_R:Out" ]
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

if sink_exists "$EQ"; then
	# Already running: change the filters live, no restart needed.
	id=$(pw-cli ls Node | awk -v n="node.name = \"$EQ\"" '/^\tid /{gsub(",","",$2); id=$2} index($0,n){print id; exit}')
	[ -n "$id" ] || die "can't find the equaliser node; run: systemctl --user restart pipewire pipewire-pulse wireplumber"
	pw-cli set-param "$id" Props "{ params = [
		\"treb_L:Gain\" $T \"treb_R:Gain\" $T \"tw_lv_L:Gain\" $TW \"tw_lv_R:Gain\" $TW
		\"bass_L:Gain\" $B \"bass_R:Gain\" $B \"wf_lv_L:Gain\" $WF \"wf_lv_R:Gain\" $WF ] }" >/dev/null
	echo "Equaliser: bass $B dB, treble $T dB (applied now; kept after a reboot)."
else
	# First time: start it (sound stops for a moment), keep the same loudness.
	v=$(vol_pct "$HW")
	restart_pw
	wait_sink "$EQ" || die "the equaliser didn't start. Check: journalctl --user -u pipewire -b | tail -20
       To undo: rm $CONF; systemctl --user restart pipewire pipewire-pulse wireplumber"
	wait_sink "$HW" || true
	pactl set-default-sink "$EQ"
	pactl set-sink-volume "$EQ" "$v%"     # your volume control now sets this one
	pactl set-sink-volume "$HW" 100%      # and the speakers pass it through
	echo "Equaliser on: bass $B dB, treble $T dB. Default output: \"iMac Speakers (EQ)\" (volume $v%)."
	echo "Change it any time with: bash tools/eq.sh BASS TREBLE"
fi
