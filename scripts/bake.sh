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


# Build all source components.
if [ -d "${ROOT}/src" ]; then
    find "${ROOT}/src" -type f -name Makefile -print |
    while IFS= read -r makefile; do
        component="$(dirname "$makefile")"

        echo "Cleaning ${component#"$ROOT"/}..."
        make -C "$component" clean

        echo "Building ${component#"$ROOT"/}..."
        make -C "$component"
    done
fi



mkdir -p "${ROOT}/dist"
rm -f "$OUT"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "${ROOTFS}/." "$STAGE/"

LIST="${STAGE}/../.symlink-candidates.$$"
find "$STAGE" -type f -size -256c > "$LIST"
while IFS= read -r f; do
    [ "$(wc -l < "$f")" -le 1 ] || continue
    target=""
    IFS= read -r target < "$f" || true
    [ -n "$target" ] || continue
    case "$target" in
        *[[:space:]]*|*[![:print:]]*) continue ;;
    esac
    case "$target" in
        /*) resolved="${STAGE}${target}" ;;
        *)  resolved="$(dirname "$f")/${target}" ;;
    esac
    [ -e "$resolved" ] || continue
    rm -f "$f"
    ln -s "$target" "$f"
    echo "Fixed symlink: ${f#"$STAGE"/} -> ${target}"
done < "$LIST"
rm -f "$LIST"

# Make sure /bin/sh exists even if it was missing entirely.
if [ ! -e "${STAGE}/bin/sh" ] && [ -e "${STAGE}/bin/busybox" ]; then
    ln -sf busybox "${STAGE}/bin/sh"
    echo "Created missing symlink: bin/sh -> busybox"
fi

chmod +x "${STAGE}/init" "${STAGE}"/bin/* "${STAGE}"/hooks/*/* "${STAGE}"/etc/profile.d/* 2>/dev/null || true
git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null > "${STAGE}/GIT_HASH" || printf 'unknown\n' > "${STAGE}/GIT_HASH"

# Sanity check: /init needs a working interpreter, otherwise the kernel
# panics with "Requested init /init failed (error -8)".
if [ "$(head -c 4 "${STAGE}/bin/sh" 2>/dev/null | od -An -c | tr -d ' ')" != '177ELF' ]; then
    echo "ERROR: bin/sh does not resolve to an ELF binary; the image would not boot." >&2
    exit 1
fi

(cd "$STAGE" && find . -mindepth 1 -print0 \
    | LC_ALL=C sort -z \
    | cpio --null -o -H newc -R 0:0 --quiet) \
    | gzip -9 > "$OUT"

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
