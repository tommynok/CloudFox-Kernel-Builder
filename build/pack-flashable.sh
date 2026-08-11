#!/usr/bin/env bash
set -euo pipefail

# Pack a built kernel into a universal, self-patching flashable zip for
# CloudFox kernels.
#
# The zip contains the kernel image, meta.inf (manifest) and a recovery
# update-binary that patches the CURRENT device boot partition on-device with
# ksud (`boot-patch --no-install`) and flashes it straight back to
# /dev/block/by-name/boot$SLOT.
#
# ksud comes from the KernelSU project but is used here strictly as a boot-image
# repacker -- a stand-in for magiskboot/mkbootimg. `--no-install` makes it
# replace the kernel blob and nothing else: no kernelsu.ko LKM, no ksuinit, no
# ramdisk changes of any kind. The installer therefore neither adds nor removes
# root; whatever the device's boot image was patched with (Magisk, KernelSU, or
# nothing at all) survives the flash untouched, and rooting stays entirely the
# user's decision. Whether the kernel itself carries root is a compile-time
# matter decided by the kernelsu defconfig fragment, excluded by default.
#
# Because patching happens on the device, no stock boot.img is needed: the zip
# works on any device with a matching KMI (boot header v3+, which is what ksud
# supports).
#
# Environment:
#   KERNEL_IMAGE        Kernel image to install (raw Image; ksud recompresses
#                       it to match the device boot image's kernel codec, so
#                       any stock compression is supported)
#   KSUD_ARM64          ksud binary for aarch64-linux-android
#   KSUD_ARMV7          ksud binary for armv7-linux-androideabi
#   KSUD_BASE           Fallback: URL prefix (release download base) where
#                       ksu-ksud-<target>.zip is fetched from
#   ZIP_OUT             Output zip path (default: ./cloudfox-kernel-flash.zip)
#   KMI                 Kernel Module Interface id (default: android12-5.10)
#   KERNEL_KERNELSU     meta.inf manifest value: true only when the kernel was
#                       compiled with KernelSU (CONFIG_KSU=y). Default false,
#                       matching the default root-free build.
#
# Options:
#   -h, --help          Show this help

SCRIPT_NAME=${0##*/}

KERNEL_IMAGE=${KERNEL_IMAGE:-}
KSUD_ARM64=${KSUD_ARM64:-}
KSUD_ARMV7=${KSUD_ARMV7:-}
KSUD_BASE=${KSUD_BASE:-}
ZIP_OUT=${ZIP_OUT:-$PWD/cloudfox-kernel-flash.zip}
KMI=${KMI:-android12-5.10}
KERNEL_KERNELSU=${KERNEL_KERNELSU:-false}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
# Bound only the connect phase: slows/dies on a hanging endpoint instead of the
# host TCP connect timeout (~130s) x --retry 3; alive-but-slow stays uncapped.
curl_dl() { curl --connect-timeout 10 "$@"; }

usage() {
    cat <<EOF
Usage: ./$SCRIPT_NAME [options]

Packs a built kernel into a universal self-patching flashable zip. The zip's
recovery update-binary runs the ksud binary on-device as a boot-image repacker,
replaces the kernel blob in the current boot image (\`boot-patch --no-install\`:
the ramdisk, and any root installed in it, is left untouched) and flashes the
result to /dev/block/by-name/boot\$SLOT (current-slot detection). No root is
installed or removed by this package.

Environment: KERNEL_IMAGE (required), KSUD_ARM64, KSUD_ARMV7 or KSUD_BASE,
ZIP_OUT, KMI, KERNEL_KERNELSU.

Options:
  -h, --help           Show this help
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$KERNEL_IMAGE" ] && [ -f "$KERNEL_IMAGE" ] \
    || die "KERNEL_IMAGE not found: ${KERNEL_IMAGE:-<unset>}"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

cp -f "$KERNEL_IMAGE" "$stage/kernel"

# Fetch missing ksud binaries from KSUD_BASE when a path was not given.
fetch_ksud() {
    local target=$1 dest=$2
    if [ -n "$dest" ] && [ -f "$dest" ]; then return 0; fi
    if [ -z "$KSUD_BASE" ]; then die "no $target ksud (set KSUD_$([ "$target" = aarch64-linux-android ] && echo ARM64 || echo ARMV7) or KSUD_BASE)"; fi
    info "fetching ksu-ksud-$target.zip from the prebuilt release"
    if ! curl_dl -fsSL --retry 3 -o "$stage/ksud-$target.zip" \
        "$KSUD_BASE/ksu-ksud-$target.zip"; then
        die "failed to fetch ksu-ksud-$target.zip from $KSUD_BASE"
    fi
    unzip -oq "$stage/ksud-$target.zip" -d "$stage/unpack-$target"
    local bin
    bin=$(find "$stage/unpack-$target" -type f -name ksud -print -quit)
    [ -n "$bin" ] || die "no ksud binary inside ksu-ksud-$target.zip"
    cp -f "$bin" "$stage/ksud-$target"
    chmod 755 "$stage/ksud-$target"
    rm -rf "$stage/ksud-$target.zip" "$stage/unpack-$target"
    ok "ksud-$target ready"
}

# Prepare one ksud binary from an explicit path, or fetch it from KSUD_BASE.
# A missing binary is a hard error: packing a zip without ksud would only
# fail on device ("no ksud for $ARCH in package"), so fail here instead.
prepare_ksud() { # <target> <dest> <src>
    local target=$1 dest=$2 src=$3
    if [ -n "$src" ]; then
        cp -f "$src" "$dest"
        chmod 755 "$dest"
    elif [ -n "$KSUD_BASE" ]; then
        fetch_ksud "$target" "$dest"
    else
        die "no ksud for $target (set KSUD_ARM64/KSUD_ARMV7 or KSUD_BASE)"
    fi
}

# The two ksud fetches are independent and network-bound; overlap them.
pids=() rc=0
prepare_ksud aarch64-linux-android "$stage/ksud-aarch64-linux-android" "$KSUD_ARM64" & pids+=("$!")
prepare_ksud armv7-linux-androideabi "$stage/ksud-armv7-linux-androideabi" "$KSUD_ARMV7" & pids+=("$!")
for pid in "${pids[@]}"; do
    wait "$pid" || rc=1
done
[ "$rc" -eq 0 ] || die "one or more ksud binaries failed"

mkdir -p "$stage/META-INF/com/google/android"

# meta.inf: payload manifest (KernelSU integrated-kernel style keys + ours).
# KERNEL_KERNELSU describes the kernel blob, not the installer: false for the
# default root-free build, overridable for a run that opted into CONFIG_KSU=y.
{
    printf 'KERNEL_BOOT_IMAGE=boot.img\n'
    printf 'KERNEL_BOOT_IMAGE_FOLDER=.\n'
    printf 'KERNEL_BOOT_IMAGE_AB=true\n'
    printf 'KERNEL_KMI=%s\n' "$KMI"
    printf 'KERNEL_KERNELSU=%s\n' "$KERNEL_KERNELSU"
} > "$stage/meta.inf"

# update-binary: recovery installer invoked as
#   update-binary <version> <out_fd> <zipfile>
# Detects the current slot, reads the live boot partition, runs the ksud
# binary on-device to replace the kernel and flashes the result back to
# /dev/block/by-name/boot$SLOT.
cat > "$stage/META-INF/com/google/android/update-binary" <<'INSTALLER'
#!/sbin/sh
# CloudFox universal kernel installer: replaces the kernel in the current boot
# partition on-device with ksud and flashes it back to boot$SLOT.

OUTFD=$2
ZIPFILE=$3
TMPDIR=/dev/tmp/cloudfox

ui_print() {
    echo "ui_print $1" > "/proc/self/fd/$OUTFD"
    echo "ui_print" > "/proc/self/fd/$OUTFD"
}

die() {
    ui_print "CloudFox: $1"
    exit 1
}

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# Current slot: ro.boot.slot_suffix ("_a"/"_b"), ro.boot.slot ("a"/"b"), or
# androidboot.slot_suffix on the kernel cmdline. Empty means non-A/B.
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
[ -z "$SLOT" ] && SLOT=$(getprop ro.boot.slot 2>/dev/null)
[ -n "$SLOT" ] && [ "${SLOT#_}" = "$SLOT" ] && SLOT="_$SLOT"
if [ -z "$SLOT" ]; then
    SLOT=$(tr ' ' '\n' < /proc/cmdline | grep '^androidboot.slot_suffix=' | cut -d= -f2)
    [ -n "$SLOT" ] && [ "${SLOT#_}" = "$SLOT" ] && SLOT="_$SLOT"
fi
[ -n "$SLOT" ] && ui_print "- Detected slot: $SLOT" || ui_print "- Non-A/B device"

# Resolve /dev/block/by-name/<name>[$SLOT], falling back to the unsuffixed path.
resolve_partition() {
    local base=$1
    if [ -n "$SLOT" ] && [ -b "$base$SLOT" ]; then
        echo "$base$SLOT"
        return 0
    fi
    if [ -b "$base" ]; then
        echo "$base"
        return 0
    fi
    return 1
}

unzip -o "$ZIPFILE" -d "$TMPDIR" >/dev/null 2>&1 || die "cannot extract $ZIPFILE"
[ -f "$TMPDIR/kernel" ] || die "kernel missing from package"

# Pick the ksud binary for this device architecture.
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) KSUD="$TMPDIR/ksud-aarch64-linux-android" ;;
    arm*|armv7l)   KSUD="$TMPDIR/ksud-armv7-linux-androideabi" ;;
    *) die "unsupported architecture: $ARCH" ;;
esac
[ -x "$KSUD" ] || die "no ksud for $ARCH in package"
chmod 755 "$KSUD"
ui_print "- Using ksud ($ARCH)"

BOOT=$(resolve_partition /dev/block/by-name/boot) || die "boot partition not found"
dd if="$BOOT" of="$TMPDIR/boot.img" bs=4M 2>/dev/null || die "cannot read $BOOT"
[ "$(dd if="$TMPDIR/boot.img" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] \
    || die "boot partition is not a boot image (unexpected content)"

# --no-install makes ksud replace the kernel image only and leave the ramdisk
# exactly as it was, so this installer never adds or removes root: a device
# patched with Magisk or KernelSU keeps it, an unrooted device stays unrooted.
# The kernel codec of the device boot image is matched automatically (ksud
# recompresses the new kernel).
ui_print "- Replacing kernel (ramdisk and root setup left untouched)..."
"$KSUD" boot-patch \
    --boot "$TMPDIR/boot.img" \
    --kernel "$TMPDIR/kernel" \
    --no-install \
    -o "$TMPDIR" \
    --out-name boot-new.img >/dev/null 2>&1 \
    || die "ksud boot-patch failed"
[ -f "$TMPDIR/boot-new.img" ] || die "ksud produced no output image"
[ "$(dd if="$TMPDIR/boot-new.img" bs=8 count=1 2>/dev/null)" = "ANDROID!" ] \
    || die "patched boot.img failed validation"

dd if="$TMPDIR/boot-new.img" of="$BOOT" bs=4M 2>/dev/null || die "cannot flash $BOOT"
sync
ui_print "- Flashed patched boot -> $BOOT"

ui_print "- Done. Reboot to boot CloudFox."
exit 0
INSTALLER
chmod 755 "$stage/META-INF/com/google/android/update-binary"

rm -f "$ZIP_OUT"
python3 - "$stage" "$ZIP_OUT" <<'PY'
import shutil, sys
stage, out = sys.argv[1], sys.argv[2]
shutil.make_archive(out[: -len(".zip")] if out.endswith(".zip") else out, "zip", stage)
PY
[ -f "$ZIP_OUT" ] || mv -f "${ZIP_OUT%.zip}.zip" "$ZIP_OUT"

ok "flashable zip: ${ZIP_OUT##*/}"
if [[ "$ZIP_OUT" == */* ]]; then
    (cd "${ZIP_OUT%/*}" && ls -la "${ZIP_OUT##*/}")
else
    ls -la "${ZIP_OUT}"
fi
