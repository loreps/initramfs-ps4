#!/bin/sh
. /functions/00-core.sh
. /functions/40-install.sh
if mountpoint -q /newroot; then
	einfo "Creating folders on /newroot..."
	ps4_prepare_newroot
	einfo "Done!"
else
	eerror "/newroot is not a mountpoint, run find-install.sh first."
	exit 1
fi
