#!/bin/sh

# PS4 storage, southbridge detection, and status LED helpers.
ps4hdd_part() {
	for p in /dev/sd?27; do
		if [ -b "${p}" ]; then
			kernel_msg_lvl 7 "PS4 internal partition is ${p}"
			echo "${p}"
			return 0
		fi
	done
	return 1
}


ps4_change_led() {
	local led_base='/sys/class/leds'
	local color="${1:-}"
	local led_path led_color target

	if [ -z "${color}" ]; then
		return 2
	fi

	target=''
	for led_path in "${led_base}"/ps4:*:status/brightness; do
		[ -e "${led_path}" ] || continue
		led_color=${led_path##*/ps4:}
		led_color=${led_color%:status/brightness}
		if [ "${led_color}" = "${color}" ]; then
			target="${led_path}"
			break
		fi
	done
	if [ -z "${target}" ]; then
		kernel_msg_lvl 7 "LED: no ${color} status LED found"
		return 1
	fi

	for led_path in "${led_base}"/ps4:*:status/brightness; do
		[ -w "${led_path}" ] || continue
		printf '0\n' > "${led_path}" || return 1
	done
	sleep 1
	printf '255\n' > "${target}"
	kernel_msg_lvl 7 "LED: set to ${color}"
}

ps4hdd_open() {
	mountpoint -q /ps4hdd && return 0
	if ! [ -b /dev/mapper/ps4hdd ]; then
		if ! [ -r /key/eap_hdd_key.bin ]; then
			ewarn "No /key/eap_hdd_key.bin, the internal drive can not be opened."
			return 1
		fi
		local part
		if ! part="$(ps4hdd_part)"; then
			ewarn "No PS4 internal drive found (no /dev/sd?27)."
			return 1
		fi
		kernel_msg "Opening ${part} as /dev/mapper/ps4hdd"
		if ps4_is_southbridge "aeolia"; then
			cryptsetup -d /key/eap_hdd_key.bin --cipher aes-xts-plain64 -s 256 --offset 0 create ps4hdd "${part}" || { eerror "cryptsetup failed on ${part}."; return 1; }
		else
			cryptsetup -d /key/eap_hdd_key.bin --cipher aes-xts-plain64 -s 256 --offset 0 --skip 111669149696 create ps4hdd "${part}" || { eerror "cryptsetup failed on ${part}."; return 1; }
		fi
	fi
	mkdir -p /ps4hdd
	if ! mount -t ufs -o ufstype=ufs2 /dev/mapper/ps4hdd /ps4hdd; then
		eerror "Could not mount /dev/mapper/ps4hdd on /ps4hdd."
		return 1
	fi
	kernel_msg "Mounted /dev/mapper/ps4hdd on /ps4hdd"
}

ps4_southbridge() {
	local sb
	case "$(cat /sys/bus/pci/devices/0000:00:14.4/device 2>/dev/null)" in # use a pci device for the southbridge check (thanks rmux)
		0x90a1) sb="Aeolia" ;;
		0x90cc) sb="Belize" ;;
		0x90db) sb="Baikal" ;;
		*) sb="Unknown Southbridge" ;;
	esac

	kernel_msg_lvl 7 "Southbridge detected: ${sb}"
	printf '%s\n' "$sb"
}

ps4_is_southbridge() {
	local target="${1:-}" current
	[ -n "$target" ] || return 1
	current="$(ps4_southbridge)" || return 1

	target="$(printf '%s' "$target" | tr 'A-Z' 'a-z')"
	current="$(printf '%s' "$current" | tr 'A-Z' 'a-z')"

	[ "$current" = "$target" ]
}

ps4_southbridge_code() {
	case "${1:-$(ps4_southbridge)}" in
		"Aeolia") echo 0x10100 ;;
		"Belize") echo 0x20100 ;;
		"Baikal") echo 0x30100 ;;
		"Unknown Southbridge") echo 0x????? ;;
		*) return 1 ;;
	esac
}

ps4_southbridge_name() {
	case "${1:-$(ps4_southbridge_code)}" in
		0x10100) echo "Aeolia" ;;
		0x20100) echo "Belize" ;;
		0x30100) echo "Baikal" ;;
		0x?????) echo "Unknown Southbridge" ;;
		*) return 1 ;;
	esac
}
