#!/bin/sh

# Installation discovery and distro archive helpers.
ps4_wait_disks() {
	local n=0
	kernel_msg_lvl 7 "Waiting up to ${1:-8}s for LABEL=psxitarch"
	while [ "${n}" -lt "${1:-8}" ]; do
		findfs LABEL=psxitarch >/dev/null 2>&1 && return 0
		sleep 1
		n=$((n + 1))
	done
	kernel_msg_lvl 7 "Gave up waiting for LABEL=psxitarch"
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

ps4_release_image() {
	# Detach loop devices still backed by the image; mkfs refuses a busy image.
	local img="$1" loop backing failed=''
	for loop in /dev/loop*; do
		[ -b "${loop}" ] || continue
		backing="$(cat "/sys/block/${loop##*/}/loop/backing_file" 2>/dev/null)"
		[ "${backing}" = "${img}" ] || continue
		ewarn "${loop} is still backed by ${img}, detaching it."
		losetup -d "${loop}" || failed='true'
	done
	[ -z "${failed}" ] || return 1
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
		eerror "Could not mount ${dev} on /newroot."
	fi
	ewarn "External installation not found, checking internal drive..."
	if ps4hdd_open && [ -f /ps4hdd/app/linux.img ]; then
		ps4_fsck /ps4hdd/app/linux.img
		if mount /ps4hdd/app/linux.img /newroot; then
			einfo "Mounted internal installation."
			return 0
		fi
		eerror "Could not mount /ps4hdd/app/linux.img on /newroot."
	fi
	ewarn "No installation found on internal drive either."
	return 1
}

ps4_prepare_newroot() {
	local d
	kernel_msg_lvl 7 "Creating standard directories in /newroot"
	for d in dev media mnt proc run sys tmp var/cache var/log var/tmp; do
		mkdir -p "/newroot/${d}"
	done
}

ps4_make_img() {
	_img="$1"; _size="$2"; _fs="$3"; _mode="$4"
	PS4_IMG_LOOPDEV=""
	kernel_msg "Making image ${_img}: ${_size} GB, fs ${_fs}, mode ${_mode}"

	case "${_mode}" in
		mount|loop) ;;
		*)
			eerror "ps4_make_img: mode must be 'mount' or 'loop'."
			return 1
		;;
	esac

	# Sparse file of the requested size
	if ! dd if=/dev/null of="${_img}" bs=1048576 count=0 seek="$((_size * 1024))" 2>/dev/null; then
		eerror "Could not create ${_img}."
		return 1
	fi
	kernel_msg_lvl 7 "Sparse file ${_img} created"

	case "${_fs}" in
		1) mkfs.ext4 -q -F -O ^orphan_file,^metadata_csum_seed "${_img}" ;;
		2) mkfs.btrfs -q -f "${_img}" ;;
		*)
			eerror "ps4_make_img: unknown file system '${_fs}'."
			rm -f "${_img}"
			return 1
		;;
	esac
	if [ "$?" -ne 0 ]; then
		eerror "Could not create the file system."
		rm -f "${_img}"
		return 1
	fi
	kernel_msg_lvl 7 "File system created on ${_img}"

	case "${_mode}" in
		mount)
			if ! mount "${_img}" /newroot; then
				eerror "Could not mount ${_img} on /newroot."
				return 1
			fi
			kernel_msg "Mounted ${_img} on /newroot"
		;;
		loop)
			_dev="$(losetup -f)" || {
				eerror "No free loop device."
				return 1
			}
			if ! losetup "${_dev}" "${_img}"; then
				eerror "Could not attach a loop device to ${_img}."
				return 1
			fi
			PS4_IMG_LOOPDEV="${_dev}"
			kernel_msg "Attached ${_img} as ${_dev}"
		;;
	esac
}

ps4_find_distro() {
	local f
	for f in distro.tar.xz distro.tar.gz distro.tar.bz2 distro.tar psxitarch.tar.xz; do
		if [ -f "$1/${f}" ]; then
			kernel_msg_lvl 7 "Found distro archive $1/${f}"
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
		kernel_msg_lvl 7 "Current setup is on /ps4hdd/system/boot"
		echo "/ps4hdd/system/boot"
		return 0
	fi
	if [ -f /temp/initramfs.cpio.gz ]; then
		kernel_msg_lvl 7 "Current setup is on /temp"
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
	kernel_msg "Extracting $1 to /newroot"
	set -o pipefail
	pv -pterb -s "$(stat -c %s "$1")" "$1" | tar -x ${compression} -f - -C /newroot --numeric-owner
	local rc=$?
	set +o pipefail
	if [ "${rc}" -eq 0 ]; then
		kernel_msg "Extraction finished"
	else
		eerror "Extraction failed (exit ${rc})."
	fi
	return "${rc}"
}
