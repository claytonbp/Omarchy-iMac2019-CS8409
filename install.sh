#!/bin/bash
# install.sh -- install the cs8409-apple speaker driver on a fresh Omarchy
# (Arch) system running on an iMac19,1 (27-inch, 2019).
#
#   sudo ./install.sh          install build tools, the matching kernel
#                              headers, the driver (via DKMS) and its settings
#   sudo ./install.sh --remove remove the driver; the stock one comes back
#
# Reboot afterwards, then run tools/check.sh. PipeWire settings are a separate
# step for your normal user: INSTALL.md, step 7.
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
	echo "(PipeWire settings from INSTALL.md step 7 are in ~/.config/pipewire/; delete them separately.)"
	exit 0
fi

# 1. Is this the right hardware? (warn only; the module itself checks the codec ID)
if grep -qh 'Subsystem Id: 0x106b1000' /proc/asound/card*/codec#* 2>/dev/null; then
	echo "Found the iMac19,1 CS8409 codec (subsystem 0x106b1000)."
else
	echo "WARNING: no CS8409 codec with subsystem 0x106b1000 found in /proc/asound."
	echo "         This driver was written and tested only on an iMac19,1."
	read -r -p "Continue anyway? [y/N] " a; [ "$a" = y ] || exit 1
fi

# 2. Is the kernel one this driver has been checked against? (must match dkms.conf)
kver=$(uname -r)
if ! [[ $kver =~ ^7\.[23]([.-]|$) ]]; then
	die "kernel $kver is not one this driver has been checked against (7.2.x, 7.3.x).
       Building it with out-of-date private kernel headers could misbehave, so this
       script stops here. See INSTALL.md, \"Kernel updates\", to update the driver source."
fi
case "$kver" in 7.2.*) echo "Kernel $kver: tested on this iMac." ;;
                *)     echo "Kernel $kver: build-checked (7.3.1), not yet tested on the iMac." ;; esac

# 3. Build tools and the headers for the running kernel
kpkg=$(pacman -Qqo "/usr/lib/modules/$kver/vmlinuz" 2>/dev/null || true)
[ -n "$kpkg" ] || die "can't tell which package owns kernel $kver"
echo "Kernel $kver comes from package '$kpkg'; installing '$kpkg-headers' and build tools."
pacman -S --needed --noconfirm base-devel dkms git alsa-utils alsa-tools python libpulse swh-plugins "$kpkg-headers"
[ -d "/usr/lib/modules/$kver/build" ] || die "headers for $kver are not in place; reboot into the newest kernel and retry"

# 4. Driver via DKMS (rebuilt automatically on kernel updates)
make -C driver install KVER="$kver"
dkms status cs8409-apple -k "$kver" | grep ': installed' >/dev/null \
	|| die "DKMS did not report cs8409-apple as installed for $kver (see: dkms status)"

# 5. Settings
install -m 0644 config/modprobe.d/cs8409-apple.conf /etc/modprobe.d/cs8409-apple.conf
echo "Installed /etc/modprobe.d/cs8409-apple.conf"

# (fails harmlessly on an exFAT USB stick, which can't store executable flags)
chmod +x tools/*.sh 2>/dev/null || true
echo
echo "Done. Now reboot, then run:"
echo "  ./tools/check.sh          # should show Codec: Cirrus Logic CS8409/CS42L83"
echo "  sudo ./tools/tone-test.sh # one quiet beep per speaker"
echo "Then INSTALL.md step 7 (as your normal user) for everyday sound."
