#!/bin/sh

# Mount management and the switch-root boot handoff.

boot_newroot() {
	init="${init:-/sbin/init}"
	einfo "Switching root to /newroot and executing ${init}."
	if ! [ -e "/newroot/${init}" ]; then
		die "There is no executable '/newroot/${init}'."
	fi
	if ! [ -x "/newroot/${init}" ]; then
		die "This is not bootable, you probably extracted this wrong."
	fi
	exec env -i \
		TERM="${TERM:-linux}" \
		PATH="${PATH:-/bin:/sbin:/usr/bin:/usr/sbin}" \
		switch_root /newroot "${init}"
}

emount() {
	while [ "$#" -gt 0 ]; do
		case $1 in
			'/dev')
				local devmountopts='nosuid,relatime,size=10240k,mode=755'
				if grep -q 'devtmpfs' '/proc/filesystems'; then
					einfo "Mounting /dev (devtmpfs)..."
					run mount -t devtmpfs -o ${devmountopts} devtmpfs /dev
				else
					mdev_used=true
					einfo "Mounting /dev (mdev over tmpfs)..."
					run mount -t tmpfs -o ${devmountopts} dev /dev
					run touch /etc/mdev.conf
					run echo /sbin/mdev > /proc/sys/kernel/hotplug
					run mdev -s
					# mdev can create pktcdvd as a file, but udev expects a directory.
					if [ -c '/dev/pktcdvd' ]; then
						run rm '/dev/pktcdvd'
						run mkdir '/dev/pktcdvd'
						run mknod '/dev/pktcdvd/control' c 10 61
					fi
				fi
			;;
			'/proc')
				einfo "Mounting /proc..."
				run mount -t proc proc /proc
			;;
			'/sys')
				einfo "Mounting /sys..."
				run mount -t sysfs sysfs /sys
			;;
			*) eerror "emount() does not understand \"$1\"" ;;
		esac
		shift
	done
}

eumount() {
	while [ "$#" -gt 0 ]; do
		einfo "Unmounting ${1}..."
		run umount "$1"
		shift
	done
}

moveDev() {
	einfo "Moving /dev to /newroot/dev..."
	if mountpoint -q /dev/pts; then
		umount -l /dev/pts
	fi
	if [ "${mdev_used:-false}" = 'true' ] && [ -e /proc/sys/kernel/hotplug ]; then
		run echo '' > /proc/sys/kernel/hotplug
	fi
	run mount --move /dev /newroot/dev
}
