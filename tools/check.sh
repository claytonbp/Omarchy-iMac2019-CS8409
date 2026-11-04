#!/bin/bash
# Shows whether the Apple CS8409 module is loaded and what it found.
echo "== Codec (want: CS8409/CS42L83, 0x106b1000)"
grep -hE 'Codec:|Subsystem Id' /proc/asound/card*/codec#0
echo; echo "== Module file in use (want: .../updates/dkms/...)"
modinfo -F filename snd_hda_codec_cs8409
echo; echo "== DKMS"
dkms status cs8409-apple
echo; echo "== Driver log for this boot"
journalctl -k -b --no-pager | grep -E 'apple:|cs8409' | sed 's/^.*snd_hda_codec_cs8409 //'
echo; echo "== Playback devices"
aplay -l | grep -E '^card'
