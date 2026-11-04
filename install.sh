#!/bin/bash
# install.sh -- install the cs8409-apple speaker driver on a fresh Omarchy
# (Arch) system running on an iMac19,1 (27-inch, 2019).
#
#   sudo ./install.sh          install build tools, the matching kernel
#                              headers, the driver (via DKMS) and its settings
#   sudo ./install.sh --remove remove the driver; the stock one comes back
#
# Reboot afterwards, then run tools/check.sh.
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo: sudo ./install.sh"
command -v pacman >/dev/null || die "this script is for Arch-based systems (Omarchy)"

if [ "${1:-}" = "--remove" ]; then
	make -C driver uninstall
	rm -f /etc/modprobe.d/cs8409-apple.conf
	depmod -a
	echo "Removed. Reboot to go back to the stock driver."
	exit 0
fi

# 1. Is this the right hardware? (warn only; the module itself checks the codec ID)
codec=$(grep -h 'Subsystem Id' /proc/asound/card*/codec#0 2>/dev/null | head -1 || true)
case "$codec" in
	*0x106b1000*) echo "Found the iMac19,1 CS8409 codec (subsystem 0x106b1000)." ;;
	*) echo "WARNING: expected CS8409 codec subsystem 0x106b1000, found: ${codec:-nothing}."
	   echo "         This driver was written and tested only on an iMac19,1."
	   read -r -p "Continue anyway? [y/N] " a; [ "$a" = y ] || exit 1 ;;
esac

# 2. Build tools and the headers for the running kernel
kver=$(uname -r)
kpkg=$(pacman -Qqo "/usr/lib/modules/$kver/vmlinuz" 2>/dev/null || true)
[ -n "$kpkg" ] || die "can't tell which package owns kernel $kver"
echo "Kernel $kver comes from package '$kpkg'; installing '$kpkg-headers' and build tools."
pacman -S --needed --noconfirm base-devel dkms git alsa-utils alsa-tools python "$kpkg-headers"
[ -d "/usr/lib/modules/$kver/build" ] || die "headers for $kver are not in place; reboot into the newest kernel and retry"

# 3. Driver via DKMS (rebuilt automatically on kernel updates)
make -C driver install KVER="$kver"

# 4. Settings
install -m 0644 config/modprobe.d/cs8409-apple.conf /etc/modprobe.d/cs8409-apple.conf
echo "Installed /etc/modprobe.d/cs8409-apple.conf"

chmod +x tools/*.sh
echo
echo "Done. Now reboot, then run:"
echo "  ./tools/check.sh          # should show Codec: Cirrus Logic CS8409/CS42L83"
echo "  sudo ./tools/tone-test.sh # one quiet beep per speaker"
