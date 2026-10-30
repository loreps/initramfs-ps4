#!/bin/sh

# PS4 storage, southbridge detection, and status LED helpers.
ps4hdd_part() {
	for p in /dev/sd?27; do
		if [ -b "${p}" ]; then
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
		return 1
	fi

	for led_path in "${led_base}"/ps4:*:status/brightness; do
		[ -w "${led_path}" ] || continue
		printf '0\n' > "${led_path}" || return 1
	done
	sleep 1
	printf '255\n' > "${target}"
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
		if ps4_is_southbridge "aeolia"; then
			cryptsetup -d /key/eap_hdd_key.bin --cipher aes-xts-plain64 -s 256 --offset 0 create ps4hdd "${part}" || return 1
		else
			cryptsetup -d /key/eap_hdd_key.bin --cipher aes-xts-plain64 -s 256 --offset 0 --skip 111669149696 create ps4hdd "${part}" || return 1
		fi
	fi
	mkdir -p /ps4hdd
	if ! mount -t ufs -o ufstype=ufs2 /dev/mapper/ps4hdd /ps4hdd; then
		eerror "Could not mount /dev/mapper/ps4hdd on /ps4hdd."
		return 1
	fi
}

ps4_southbridge() {
	local sb
	sb=$(dmesg | grep -m1 southbridge | cut -d: -f5 | cut -d"[" -f1 | xargs)
	# Older kernels omit this line; the kernel release identifies Baikal systems.
	if [ -z "$sb" ]; then
		case "$(uname -r)" in
			*[Bb]aikal*) sb="Baikal A0" ;;
		esac
	fi

	[ -n "$sb" ] || sb="Unknown Southbridge"
	printf '%s\n' "$sb"
}

ps4_is_southbridge() {
	local target="${1:-}" current
	[ -n "$target" ] || return 1
	current="$(ps4_southbridge)" || return 1

	target="$(printf '%s' "$target" | tr 'A-Z' 'a-z')"
	current="$(printf '%s' "$current" | tr 'A-Z' 'a-z')"

	case "$current" in
		"$target"|"$target "*) return 0 ;;
	esac
	return 1
}

ps4_southbridge_code() {
	case "${1:-$(ps4_southbridge)}" in
		"Aeolia A0") echo 0x10100 ;;
		"Aeolia A1") echo 0x10200 ;;
		"Aeolia A2") echo 0x10300 ;;
		"Belize A0") echo 0x20100 ;;
		"Belize B0") echo 0x20200 ;;
		"Baikal A0") echo 0x30100 ;;
		"Baikal B0") echo 0x30200 ;;
		"Baikal B1") echo 0x30201 ;;
		"Belize2 A0") echo 0x40100 ;;
		"Unknown Southbridge") echo 0x????? ;;
		*) return 1 ;;
	esac
}

ps4_southbridge_name() {
	case "${1:-$(ps4_southbridge_code)}" in
		0x10100) echo "Aeolia A0" ;;
		0x10200) echo "Aeolia A1" ;;
		0x10300) echo "Aeolia A2" ;;
		0x20100) echo "Belize A0" ;;
		0x20200) echo "Belize B0" ;;
		0x30100) echo "Baikal A0" ;;
		0x30200) echo "Baikal B0" ;;
		0x30201) echo "Baikal B1" ;;
		0x40100) echo "Belize2 A0" ;;
		0x?????) echo "Unknown Southbridge" ;;
		*) return 1 ;;
	esac
}