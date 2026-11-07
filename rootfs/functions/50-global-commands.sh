#!/bin/sh
fix_install() {
  if mountpoint -q /newroot; then
  	einfo "Creating folders on /newroot..."
  	ps4_prepare_newroot
  	einfo "Done!"
  else
  	eerror "/newroot is not a mountpoint, run find-install first."
  	exit 1
  fi
}
# idk what the point of tihs one is lmao
find_install() {
  kernel_msg_lvl 7 "find_install called"
  ps4_find_install
}

boot_archiso() {
    kernel_msg_lvl 7 "boot_archiso called"
    _boot_archiso # this oneis from 41-arch.sh
}
