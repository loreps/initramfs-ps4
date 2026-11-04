#!/bin/sh

# Installation discovery and distro archive helpers.
ps4_wait_disks() {
	local n=0
	while [ "${n}" -lt "${1:-8}" ]; do
		findfs LABEL=psxitarch >/dev/null 2>&1 && return 0
		sleep 1
		n=$((n + 1))
	done
}

ps4_fsck() {
	case "$(blkid "$1" 2>/dev/null)" in
		*'TYPE="ext'*)
			einfo "Checking $1 ..."
			e2fsck -p "$1"
			if [ "$?" -ge 4 ]; then
				ewarn "e2fsck found errors it could not fix on $1."
				ewarn "Run 'e2fsck -f $1' by hand if the boot fails."
			fi
		;;
	esac
}

ps4_find_install() {
	if mountpoint -q /newroot && ! umount /newroot; then
		eerror "/newroot is busy, can not search again."
		return 1
	fi
	local dev
	if dev="$(findfs LABEL=psxitarch 2>/dev/null)"; then
		ps4_fsck "${dev}"
		if mount "${dev}" /newroot; then
			einfo "Mounted external installation (${dev})."
			return 0
		fi
	fi
	if ps4hdd_open && [ -f /ps4hdd/app/linux.img ]; then
		ps4_fsck /ps4hdd/app/linux.img
		if mount /ps4hdd/app/linux.img /newroot; then
			einfo "Mounted internal installation."
			return 0
		fi
	fi
	ewarn "No installation found on internal drive either."
	return 1
}

ps4_prepare_newroot() {
	local d
	for d in dev media mnt proc run sys tmp var/cache var/log var/tmp; do
		mkdir -p "/newroot/${d}"
	done
}

ps4_find_distro() {
	local f
	for f in distro.tar.xz distro.tar.gz distro.tar.bz2 distro.tar psxitarch.tar.xz; do
		if [ -f "$1/${f}" ]; then
			echo "$1/${f}"
			return 0
		fi
	done
	if [ -f "$1/distro.tar.zst" ]; then
		eerror "distro.tar.zst is not supported, recompress it as distro.tar.xz."
	fi
	return 1
}

ps4_current_setup() {
	if [ -f /ps4hdd/system/boot/initramfs.cpio.gz ]; then
		echo "/ps4hdd/system/boot"
		return 0
	fi
	if [ -f /temp/initramfs.cpio.gz ]; then
		echo "/temp"
		return 0
	fi
	return 1
}

ps4_extract() {
	local compression=''
	case "$1" in
		*.xz) compression='-J' ;;
		*.gz) compression='-z' ;;
		*.bz2) compression='-j' ;;
	esac
	set -o pipefail
	pv -pterb -s "$(stat -c %s "$1")" "$1" | tar -x ${compression} -f - -C /newroot --numeric-owner
	local rc=$?
	set +o pipefail
	return "${rc}"
}
