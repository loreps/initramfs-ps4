#!/bin/sh

# Device resolution and block-storage setup/resume helpers.
resolve_device() {
	# Resolve LABEL and UUID references before passing devices to storage tools.
	device="$(eval echo \$$1)"
	case "${device}" in
		LABEL\=*|UUID\=*)
			eval $1="$(findfs "$device")"
			if [ -z "$(eval echo \$$1)" ]; then
				eerror "Wrong UUID or LABEL."
				rescueshell
			fi
		;;
	esac
}

get_majorminor() {
	local device="$1"
	musthave device

	local major_hex="$(stat -L -c '%t' "${device}")"
	local minor_hex="$(stat -L -c '%T' "${device}")"

	musthave major_hex minor_hex

	if [ -n "${major_hex}" ] && [ -n "${minor_hex}" ]; then
		printf '%u:%u\n' "0x${major_hex}" "0x${minor_hex}"
	fi
}

InitializeLUKS() {
	if [ ! -f /bin/cryptsetup ]; then
		eerror "There is no cryptsetup binary into initramfs image."
		rescueshell
	fi

	musthave enc_root

	local enc_num='1'
	local dev_name="enc_root"
	local IFS=":"
	for enc_dev in ${enc_root}; do
		IFS="${default_ifs}"
		if ! [ "${enc_num}" = '1' ]; then
			dev_name="enc_root${enc_num}"
		fi

		resolve_device enc_dev
		einfo "Opening encrypted partition '${enc_dev##*/}' and mapping to '/dev/mapper/${dev_name}'."
		run echo -e "#!/bin/sh\nexit 0" > /sbin/udevadm
		run chmod 755 /sbin/udevadm

		local cryptsetup_args=""
		if ! use luks_no_discards; then
			cryptsetup_args="${cryptsetup_args} --allow-discards"
		fi

		run cryptsetup luksOpen --tries 25 ${cryptsetup_args} "${enc_dev}" "${dev_name}"
		enc_num="$((enc_num+1))"
	done
}

InitializeLVM() {
	einfo "Scaning all disks for volume groups."
	if [ -d '/etc/lvm/cache' ]; then
		# Force vgchange to scan volume groups instead of trusting a stale cache.
		run rm -rf '/etc/lvm/cache'
	fi
	run lvm vgchange -a y
}

InitializeSoftwareRaid() {
	einfo "Scaning for software raid arrays."
	if ! [ -f '/etc/mdadm.conf' ]; then
		run mdadm --examine --scan > /etc/mdadm.conf
	fi
	run mdadm --assemble --scan
	# Software RAID arrays may themselves contain partition tables.
	rereadpt
}

rereadpt() {
	for i in /dev/*; do
		if [ -b "${i}" ]; then
			blockdev --rereadpt "${i}" >/dev/null 2>&1
		fi
	done
}

SwsuspResume() {
	musthave resume
	resolve_device resume
	if [ -f '/sys/power/resume' ]; then
		local resume_majorminor="$(get_majorminor "${resume}")"
		musthave resume_majorminor
		echo "${resume_majorminor}" > /sys/power/resume
	else
		ewarn "Apparently this kernel does not support suspend."
	fi
}

UswsuspResume() {
	musthave resume
	resolve_device resume
	if [ -f '/sys/power/resume' ]; then
		run resume --resume_device "${resume}"
	else
		ewarn "Apparently this kernel does not support suspend."
	fi
}

TuxOnIceResume() {
	musthave resume
	if [ -f '/sys/power/tuxonice/do_resume' ]; then
		einfo "Sending do_resume signal to TuxOnIce."
		run echo 1 > /sys/power/tuxonice/do_resume
	else
		ewarn "Apparently this kernel does not support TuxOnIce."
	fi
}

register_bcache_devices() {
	# Register every block device; non-bcache devices are ignored by the kernel.
	if ! [ -e /sys/fs/bcache/register_quiet ]; then
		ewarn "There's no bcache interface. Missing kernel driver?"
		return 0
	fi

	for i in $(awk '$4 !~ /^(name$|$)/ { print $4 }' /proc/partitions); do
		if [ -e "/dev/${i}" ]; then
			echo "/dev/${i}" >/sys/fs/bcache/register_quiet
		else
			echo "Looks like there's no '/dev/${i}', but should be."
		fi
	done
}