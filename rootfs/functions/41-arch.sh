#!/bin/sh
ARCHISO_URL="http://mirrors.edge.kernel.org/archlinux/iso/latest/arch/x86_64/airootfs.sfs"
ARCHISO_SFS=/tmp/airootfs.sfs
ARCHISO_NEWROOT=/newroot
ARCHISO_RO=/mnt/ro
ARCHISO_RW=/mnt/rw
ARCHISO_INNER=/mnt/inner
ARCHISO_LOWER=""
ARCHISO_TARGET=""            # internal | external
ARCHISO_IMG=/ps4hdd/app/linux.img

archiso_check_kernel() {
  missing=""
  grep -qw squashfs /proc/filesystems || missing="$missing squashfs"
  grep -qw overlay  /proc/filesystems || missing="$missing overlay"
  if [ -n "$missing" ]; then
    eerror "boot_archiso: kernel is missing:$missing"
    return 1
  fi
}

# try to find the internal drive this is so fucking stupid dont put me behind a keyboar
archiso_find_internal_disk() {
  for _p in /dev/sd?27; do
    if [ -b "$_p" ]; then
      echo "${_p%27}"
      return 0
    fi
  done
  return 1
}

archiso_confirm_wipe_warning() {
  _disk="$(archiso_find_internal_disk)" || _disk="the PS4 internal drive (/dev/sdX)"

  ewarn "WARNING: ${_disk} is the PS4's internal hard drive."
  ewarn "Writing to ${_disk} (or any of its partitions) will WIPE THE ENTIRE PS4 HARD DRIVE,"
  ewarn "including the PS4 system software. Do NOT install Linux directly to it."
  eask "Type I UNDERSTAND to continue: "
  read answer
  if [ "${answer}" != 'I UNDERSTAND' ]; then
    eerror "Aborted."
    return 1
  fi
}

archiso_wizard_internal() {
  mkdir -p /ps4hdd/app
  if ! ps4hdd_open; then
    eerror "Could not open the PS4 internal drive."
    return 1
  fi

  if [ -e "$ARCHISO_IMG" ]; then
    ewarn "$ARCHISO_IMG already exists. Continuing erases it."
    eask "Type YES to erase it: "
    read answer
    if [ "${answer}" != 'YES' ]; then
      eerror "Aborted."
      return 1
    fi
    rm -f "$ARCHISO_IMG"
  fi

  free_gb="$(df -Pk /ps4hdd | awk 'END { print int($4 / 1048576) }')"
  if [ "${free_gb}" -lt 1 ]; then
    eerror "Less than 1 GB free on the internal drive."
    return 1
  fi

  eask "Enter the amount of storage to dedicate to your Linux install (1-${free_gb} GB): "
  read size
  case "${size}" in
    ''|*[!0-9]*)
      eerror "'${size}' is not a number."
      return 1
    ;;
  esac
  if [ "${size}" -lt 1 ] || [ "${size}" -gt "${free_gb}" ]; then
    eerror "Size must be between 1 and ${free_gb} GB."
    return 1
  fi

  eask "Pick your file system (1 - ext4, 2 - btrfs): "
  read fs
  case "${fs}" in
    1|2) ;;
    *)
      eerror "I don't understand this file system choice."
      return 1
    ;;
  esac

  ps4_make_img "$ARCHISO_IMG" "$size" "$fs" loop || return 1
  einfo "Image attached as ${PS4_IMG_LOOPDEV}"
}

archiso_wizard() {
  eask "Do you wish to install internally or externally? (1 - internal, 2 - external USB): "
  read choice
  case "${choice}" in
    1) ARCHISO_TARGET=internal ;;
    2) ARCHISO_TARGET=external ;;
    *)
      eerror "I don't understand this choice."
      return 1
    ;;
  esac

  if [ "$ARCHISO_TARGET" = internal ]; then
    archiso_wizard_internal || return 1
  else
    einfo "External install: nothing to do on this end, just choose your drive in the setup. "
  fi

  archiso_confirm_wipe_warning || return 1
}

archiso_download() {
  if ! SetupNetwork; then
    eerror "boot_archiso: network setup failed"
    return 1
  fi
  mkdir -p /tmp
  wget -O "$ARCHISO_SFS" "$ARCHISO_URL" || return 1
}

archiso_mount_image() {
  mkdir -p "$ARCHISO_RO" "$ARCHISO_INNER"
  mount -t squashfs -o loop,ro "$ARCHISO_SFS" "$ARCHISO_RO" || return 1
  ARCHISO_LOWER=$ARCHISO_RO

  # might have another image in it, we should probably check anyway..
  if [ -f "$ARCHISO_RO/airootfs.img" ]; then
    mount -o loop,ro "$ARCHISO_RO/airootfs.img" "$ARCHISO_INNER" || return 1
    ARCHISO_LOWER=$ARCHISO_INNER
  fi
}

archiso_mount_overlay() {
  mkdir -p "$ARCHISO_RW" "$ARCHISO_NEWROOT"
  mount -t tmpfs tmpfs "$ARCHISO_RW" || return 1
  mkdir -p "$ARCHISO_RW/up" "$ARCHISO_RW/work"
  mount -t overlay overlay \
    -o lowerdir="$ARCHISO_LOWER",upperdir="$ARCHISO_RW/up",workdir="$ARCHISO_RW/work" \
    "$ARCHISO_NEWROOT" || return 1
}

archiso_verify_newroot() {
  if [ ! -x "$ARCHISO_NEWROOT/sbin/init" ]; then
    eerror "boot_archiso: no /sbin/init in new root"
    return 1
  fi
}

archiso_ready_notice() {
  _disk="$(archiso_find_internal_disk)" || _disk="/dev/sdX"

  einfo "Everything is ready. About to switch root into the Arch ISO environment."
  einfo "Once you're booted in, run: archinstall"
  if [ "$ARCHISO_TARGET" = internal ]; then
    einfo "Pick the loop device (${PS4_IMG_LOOPDEV}) as your target, NOT ${_disk}."
  else
    einfo "Pick your external USB drive as the target, NOT ${_disk} (the PS4's internal drive)."
  fi
  eask "Press Enter to continue: "
  read _dummy
}

archiso_switch_root() {
  ps4_prepare_newroot
  run_hooks after_mount_newroot
  cleanup
  moveDev
  eumount /sys /proc
  run_hooks pre_switch_root

  exec switch_root "$ARCHISO_NEWROOT" /sbin/init
}

_boot_archiso() {
  archiso_check_kernel   || return 1
  archiso_wizard         || return 1
  archiso_download       || return 1
  archiso_mount_image    || return 1
  archiso_mount_overlay  || return 1
  archiso_verify_newroot || return 1
  archiso_ready_notice
  archiso_switch_root
}
