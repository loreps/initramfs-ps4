#!/bin/sh

# Mount management and the switch-root boot handoff.
cleanup() {
	was_shell && rm /rescueshell.pid
	kernel_msg_lvl 7 "cleanup done"
}

boot_newroot() {
	init="${init:-/sbin/init}"
	einfo "Switching root to /newroot and executing ${init}."
	if ! [ -e "/newroot/${init}" ]; then
		die "There is no executable '/newroot/${init}'."
	fi
	if ! [ -x "/newroot/${init}" ]; then
		die "This is not bootable, you probably extracted this wrong."
	fi
	if ! [ -e /BOOTANYWAY ]; then
		for i in dev sys proc run; do
			if ! mountpoint -q "/newroot/$i"; then
				die "/newroot/$i is not mounted. Booting would probably crash. Touch /BOOTANYWAY to skip this check."
			fi
		done
	else
		ewarn "/BOOTANYWAY found. Skipping mount checks, good luck."
	fi
	kernel_msg "Executing switch_root /newroot ${init}"
	exec env -i \
		TERM="${TERM:-linux}" \
		PATH="${PATH:-/bin:/sbin:/usr/bin:/usr/sbin}" \
		switch_root /newroot "${init}"
}
emount() {
	while [ "$#" -gt 0 ]; do
		case $1 in
			'/newroot')
				if mountpoint -q '/newroot'; then
					einfo "/newroot already mounted, skipping..."
				else
					einfo "Mounting /newroot..."
					musthave root
					if [ -n "${rootfstype}" ]; then
						local mountparams="${rootfsmountparams} -t ${rootfstype}"
					fi
					resolve_device root
					run mount -o ${root_rw_ro:-ro} ${mountparams} "${root}" '/newroot'
					kernel_msg "Mounted ${root} on /newroot"
				fi
			;;
			'/newroot/usr')
				if [ -f '/newroot/etc/fstab' ]; then
					while read device mountpoint fstype fsflags _; do
						if [ "${mountpoint}" = '/usr' ]; then
							if [ -d '/newroot/usr' ]; then
								einfo "Mounting /newroot/usr..."
								run mount -o "${fsflags},${root_rw_ro:-ro}" -t "${fstype}" "${device}" '/newroot/usr'
								kernel_msg "Mounted ${device} on /newroot/usr"
							else
								die "/usr in fstab present but no mountpoint /newroot/usr found."
							fi
							break
						fi
					done < '/newroot/etc/fstab'
				else
					ewarn "No /newroot/etc/fstab present."
					ewarn "Early mouting of /usr will not be done."
				fi
			;;
			'/dev')
				local devmountopts='nosuid,relatime,size=10240k,mode=755'
				if grep -q 'devtmpfs' '/proc/filesystems' && ! use mdev; then
					einfo "Mounting /dev (devtmpfs)..."
					run mount -t devtmpfs -o ${devmountopts} devtmpfs /dev
				else
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
				kernel_msg "/dev mounted"
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
	# Log first: /dev/kmsg moves away with /dev
	kernel_msg "Moving /dev to /newroot/dev"
	einfo "Moving /dev to /newroot/dev..."
	if mountpoint -q /dev/pts; then
		umount -l /dev/pts
	fi
	if use mdev; then
		run echo '' > /proc/sys/kernel/hotplug
	fi
	run mount --move /dev /newroot/dev
}

rootdelay() {
	if [ "${rootdelay}" -gt 0 2>/dev/null ]; then
		einfo "Waiting ${rootdelay}s (rootdelay)"
		run sleep ${rootdelay}
	else
		ewarn "\$rootdelay variable must be numeric and greater than zero. Skipping rootdelay."
	fi
}
