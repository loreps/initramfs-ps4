#!/bin/sh

# Logging, command-line parsing, and shared initramfs utilities.
initramfs_quiet=false

quiet_mode() {
	[ "${initramfs_quiet:-false}" = 'true' ]
}

# Write to /dev/kmsg at a given kernel log level (3=err, 4=warn, 6=info, 7=debug)
kernel_msg_lvl() {
	if [ -w /dev/kmsg ]; then
		_klvl="$1"
		shift
		printf '<%s>[initramfs-ps4]: %s\n' "${_klvl}" "$*" > /dev/kmsg
	fi
	return 0
}

kernel_msg() {
	kernel_msg_lvl 6 "$*"
}

einfo() {
	kernel_msg_lvl 6 "${*}"
	quiet_mode && return 0
	echo -ne "\033[1;30m>\033[0;36m>\033[1;36m> \033[0m${*}\n"
}

ewarn() {
	kernel_msg_lvl 4 "${*}"
	quiet_mode && return 0
	echo -ne "\033[1;30m>\033[0;33m>\033[1;33m> \033[0m${*}\n" >&2
}

eerror() {
	kernel_msg_lvl 3 "${*}"
	echo -ne "\033[1;30m>\033[0;31m>\033[1;31m> ${*}\033[0m\n" >&2
}

eask() {
	quiet_mode && return 0
	echo -ne "\033[1;30m>\033[0;35m>\033[1;35m> \033[0m${*}"
}

die() {
	eerror "$*"
	rescueshell
}

InitializeBusybox() {
	einfo "Create all the symlinks to /bin/busybox."
	run /bin/busybox --install -s
}

SetupNetwork() {
	if ! command -v ip >/dev/null 2>&1 || ! command -v udhcpc >/dev/null 2>&1; then
		eerror "The ip command or udhcpc is not available."
		return 1
	fi
	if ! [ -x /bin/udhcpc.script ]; then
		eerror "The DHCP configuration script /bin/udhcpc.script is missing."
		return 1
	fi

	for device in /sys/class/net/*; do
		[ -e "${device}" ] || continue
		interface="${device##*/}"
		[ "${interface}" = 'lo' ] && continue
		[ -e "${device}/device" ] || continue

		einfo "Bringing up ${interface} and requesting a DHCP lease..."
		if ! ip link set dev "${interface}" up; then
			ewarn "Could not bring up ${interface}."
			continue
		fi
		if udhcpc -i "${interface}" -s /bin/udhcpc.script -n -q -t 5 -T 3; then
			einfo "Network configured on ${interface}."
			return 0
		fi
	done

	eerror "Could not configure a network interface with DHCP."
	return 1
}

ps4_start_ssh() {
	einfo "Starting SSH server..."

	SetupNetwork || {
		eerror "Network initialization failed."
		return 1
	}

	dodir /etc/dropbear /var/run

	# Create a minimal root account.
	if ! grep -q '^root:' /etc/passwd 2>/dev/null; then
		echo 'root::0:0:root:/:/bin/sh' >> /etc/passwd
	fi

	# Generate a temporary host key.
	/bin/dropbearkey -t ed25519 \
		-f /etc/dropbear/dropbear_ed25519_host_key || return 1

	# Allow blank-password authentication.
	/bin/dropbear \
		-B \
		-r /etc/dropbear/dropbear_ed25519_host_key \
		-P /var/run/dropbear.pid

	einfo "SSH server started."
}

rescueshell() {
	initramfs_quiet=false
	if [ "$rescueshell" != 'true' ]; then
		ewarn "Dropping to rescueshell because of above error."
	fi

	ewarn "Rescue Shell (busybox's /bin/sh)"
	ewarn "To reboot, press 'control-alt-delete'."
	ewarn "If you wish resume booting process, run 'resume-boot'."
	if [ "$console" ] && [ -c "/dev/${console}" ]; then
		setsid sh -c "exec sh --login </dev/"${console}" >/dev/${console} 2>&1"
	elif [ -c '/dev/tty1' ]; then
		setsid sh -c 'exec sh --login </dev/tty1 >/dev/tty1 2>&1'
	else
		sh --login
	fi
	echo
	:> /rescueshell.pid
}

was_shell() {
	[ -f '/rescueshell.pid' ]
	return $?
}

run() {
	if "$@"; then
		echo "Executed: '$@'" >> /init.log
		kernel_msg_lvl 7 "Executed: '$*'"
	else
		eerror "'$@' failed."
		echo "Failed: '$@'" >> /init.log
		echo "$@" >> /.ash_history
		rescueshell
	fi
}

get_opt() {
	echo "${*#*=}"
}

run_hooks() {
	# Allow optional code injection from hooks in multiple initramfs images.
	if [ -d "/hooks/$1" ]; then
		for i in /hooks/$1/*; do
			[ "$i" = "/hooks/$1/*" ] && break
			chmod +x "$i" 2>/dev/null
			einfo "Running '$i' hook ..."
			. "$i"
		done
	fi
}

process_commandline_options() {
	for i in $(cat /proc/cmdline); do
		case "${i}" in
			initramfsdebug) set -x ;;
			root\=*) root=$(get_opt "$i") ;;
			init\=*) init=$(get_opt "$i") ;;
			enc_root\=*) enc_root=$(get_opt "$i") ;;
			luks) luks=true ;;
			lvm) lvm=true ;;
			softraid) softraid=true ;;
			rescueshell) rescueshell=true ;;
			swsusp) swsusp=true ;;
			uswsusp) uswsusp=true ;;
			tuxonice) tuxonice=true ;;
			resume\=*) resume=$(get_opt "$i") ;;
			rootfstype\=*) rootfstype=$(get_opt "$i") ;;
			rootflags\=*) rootfsmountparams="-o $(get_opt "$i")" ;;
			ro|rw) root_rw_ro=$i ;;
			rootdelay\=*) rootdelay=$(get_opt "$i") ;;
			console\=*)
				console=$(get_opt "$i")
				console="${console%,*}"
			;;
			mdev) mdev=true ;;
			luks_no_discards) luks_no_discards=true ;;
			bcache) bcache=true ;;
		esac
	done
}

has_cmdline() {
	local option="$1"
	[ -n "${option}" ] || return 1

	for i in $(cat /proc/cmdline); do
		case "${i}" in
			initramfs=*)
				local value
				value=$(get_opt "$i")
				local old_ifs="${IFS}"
				IFS=','
				for item in ${value}; do
					if [ "${item}" = "${option}" ]; then
						IFS="${old_ifs}"
						return 0
					fi
				done
				IFS="${old_ifs}"
			;;
		esac
	done
	return 1
}

use() {
	name="$(eval echo \$$1)"
	if [ -n "${name}" ] && [ "${name}" != 'false' ] && [ "${name}" != '0' ]; then
		if [ -n "$2" ]; then
			$2
		else
			return 0
		fi
	else
		return 1
	fi
}

musthave() {
	while [ -n "$1" ]; do
		if ! use "$1"; then
			eerror "The \"$1\" variable is empty, set to false or zero but shoudn't be."
			local missing_variable='true'
		fi
		shift
	done

	if [ "${missing_variable}" = 'true' ]; then
		rescueshell
	fi
}

dodir() {
	for dir in "$@"; do
		run mkdir -m 700 -p "${dir}"
	done
}

loadkeymap() {
	if [ -f /keymap ]; then
		loadkmap < /keymap
	fi
}
