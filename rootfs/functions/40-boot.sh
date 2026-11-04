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
	if ps4_is_southbridge "baikal"; then
		# The internal drive is not usable on Baikal systems.
		ewarn "External installation not found."
		return 1
	fi
	ewarn "External installation not found, checking internal drive..."
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