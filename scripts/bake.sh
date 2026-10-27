#!/bin/sh

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS="${ROOT}/rootfs"
OUT="${ROOT}/dist/initramfs.cpio.gz"

for arg in "$@"; do
    case "$arg" in
        -production|--production)
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [-production]" >&2
            exit 1
            ;;
    esac
done

mkdir -p "${ROOT}/dist"
rm -f "$OUT"

chmod +x "${ROOTFS}/init" "${ROOTFS}"/bin/* "${ROOTFS}"/hooks/*/* "${ROOTFS}"/etc/profile.d/* 2>/dev/null || true
git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null > "${ROOTFS}/GIT_HASH" || printf 'unknown\n' > "${ROOTFS}/GIT_HASH"

(cd "$ROOTFS" && find . -mindepth 1 -print0 \
    | LC_ALL=C sort -z \
    | cpio --null -o -H newc -R 0:0 --quiet) \
    | gzip -9 > "$OUT"

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
