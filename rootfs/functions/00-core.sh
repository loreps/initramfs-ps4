#!/bin/sh

# Logging, command-line parsing, and shared initramfs utilities.
initramfs_quiet=false

quiet_mode() {
	[ "${initramfs_quiet:-false}" = 'true' ]
}

einfo() {
	quiet_mode && return 0
	echo -ne "\033[1;30m>\033[0;36m>\033[1;36m> \033[0m${*}\n"
}

ewarn() {
	quiet_mode && return 0
	echo -ne "\033[1;30m>\033[0;33m>\033[1;33m> \033[0m${*}\n" >&2
}

eerror() {
	echo -ne "\033[1;30m>\033[0;31m>\033[1;31m> ${*}\033[0m\n" >&2
}

die() {
	eerror "$*"
	rescueshell
}

InitializeBusybox() {
	einfo "Create all the symlinks to /bin/busybox."
	run /bin/busybox --install -s
}

rescueshell() {
	initramfs_quiet=false
	if [ "$rescueshell" != 'true' ]; then
		ps4_change_led orange
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
}

run() {
	if "$@"; then
		echo "Executed: '$@'" >> /init.log
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
			init\=*) init=$(get_opt "$i") ;;
			console\=*)
				console=$(get_opt "$i")
				console="${console%,*}"
			;;
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