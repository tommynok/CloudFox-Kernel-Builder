#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=${0##*/}
case "$0" in
    */*) SCRIPT_DIR=$(cd "${0%/*}" && pwd) ;;
    *)   SCRIPT_DIR=$PWD ;;
esac

CLEAN=${CLEAN:-0}
SKIP_FETCH=${SKIP_FETCH:-0}
SKIP_BUILD=${SKIP_BUILD:-0}
CCACHE_OPT=${CCACHE_OPT:-}
WORK_DIR=${WORK_DIR:-"$SCRIPT_DIR/work"}
KERNEL_DIR=${KERNEL_DIR:-common}
KERNEL_REPO=${KERNEL_REPO:-https://github.com/CloudFox-INC/CloudFox-Kernel}
KERNEL_BRANCH=${KERNEL_BRANCH:-}
KERNEL_COMMIT=${KERNEL_COMMIT:-}
PREBUILTS_REPO=${PREBUILTS_REPO:-}
PREBUILTS_TAG=${PREBUILTS_TAG:-prebuilts}
ACK_PREBUILTS_BRANCH=${ACK_PREBUILTS_BRANCH:-master}
CLANG_ASSET=${CLANG_ASSET:-clang-r536225-linux-x86.tar.zst}
CLANG_UPSTREAM_REPO=${CLANG_UPSTREAM_REPO:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}
# Upstream directory name and branch used by the sparse-clone fallback when no
# prebuilt clang bundle is available. The asset name carries the version
# ("clang-r536225-linux-x86.tar.zst" -> "clang-r536225"), which is what the
# upstream repo actually calls the directory -- NOT the name the kernel's
# build.config.common pins (that one is an old ACK alias and does not exist
# upstream; fetch_clang symlinks the pinned path to whatever it resolved).
CLANG_UPSTREAM_NAME=${CLANG_UPSTREAM_NAME:-${CLANG_ASSET%%-linux-x86.tar.zst}}
# Branch mapping matches .github/workflows/prebuilts.yml: the clang 14
# toolchain lives on android14-dev, everything newer on master.
if [ -z "${CLANG_UPSTREAM_BRANCH:-}" ]; then
    case "$CLANG_UPSTREAM_NAME" in
        clang-r450784e) CLANG_UPSTREAM_BRANCH=android14-dev ;;
        *)              CLANG_UPSTREAM_BRANCH=$ACK_PREBUILTS_BRANCH ;;
    esac
fi
KBUILD_TOOLS_ASSET=${KBUILD_TOOLS_ASSET:-kernel-build-tools.tar.zst}
KBUILD_TOOLS_UPSTREAM_REPO=${KBUILD_TOOLS_UPSTREAM_REPO:-https://android.googlesource.com/kernel/prebuilts/build-tools}
BUILDTOOLS_ASSET=${BUILDTOOLS_ASSET:-build-tools.tar.zst}
BUILDTOOLS_UPSTREAM_REPO=${BUILDTOOLS_UPSTREAM_REPO:-https://android.googlesource.com/platform/prebuilts/build-tools}
GCC_HOST_UPSTREAM_REPO=${GCC_HOST_UPSTREAM_REPO:-https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8}
CLANG_URL=${CLANG_URL:-}
KBUILD_TOOLS_URL=${KBUILD_TOOLS_URL:-}
BUILDTOOLS_URL=${BUILDTOOLS_URL:-}
GAS_URL=${GAS_URL:-}
JOBS=${JOBS:-}
BUILD_CONFIG=${BUILD_CONFIG:-}
DEFCONFIG_FRAGMENT=${DEFCONFIG_FRAGMENT:-}
DEFCONFIG_FRAGMENT_EXCLUDE=${DEFCONFIG_FRAGMENT_EXCLUDE:-}
APPEND_BUILD_ENV=${APPEND_BUILD_ENV:-}
APPEND_CONFIG=${APPEND_CONFIG:-}

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
# Render a path relative to the script dir when it lives under it, so status
# messages do not leak the absolute machine layout (CI runner paths) to stdout.
rel() { case "$1" in "$SCRIPT_DIR/"*) printf '%s\n' ".${1#"$SCRIPT_DIR"}" ;; *) printf '%s\n' "$1" ;; esac; }
# Read a "export KEY=value" (or plain "KEY=value") line's value from a build
# config. Falls back to empty string regardless of quirks (|cut|...||true).
config_get() { # <file> <KEY>
    local key=$2
    grep -m1 -E "^(export[[:space:]]+)?$key=" "$1" 2>/dev/null | cut -d= -f2- | xargs || true
}
# curl for downloads, bounded only on the connect phase. A dead/hanging network
# endpoint otherwise stalls on the host TCP connect timeout (~130s on Linux),
# then retries - 3 times - stalling a many-gigabyte fetch (and the whole build
# pipeline, since run_build waits on it) for many minutes. Sticking only a
# connect timeout on never bounds a slow-but-alive transfer, so multi-GB
# clang/build-tools tarballs still download at full speed.
curl_dl() { curl --connect-timeout 10 "$@"; }

usage() {
    cat <<EOF
Usage: ./$SCRIPT_NAME [options]

Builds a CloudFox kernel with Google's build.sh (unmodified):
clones every component into the required layout under WORK_DIR,
then runs: cd WORK_DIR && BUILD_CONFIG=... ./build/build.sh

The Google kernel build scripts (kernel/build @ master-kernel-build-2021,
the revision Android 12 / 5.10 kernels build against, unmodified) and the
gcc host sysroot are shipped in this repository and copied into the
build layout; clang, kernel-build-tools and build-tools are fetched from
the PREBUILTS_TAG release of PREBUILTS_REPO by default (those bundles are
built from the Google ACK sources by .github/workflows/prebuilts.yml at
the same master-kernel-build-2021 revision).

Default layout (matching the ACK android12-5.10 manifest):

  work/
    build/                         kernel/build scripts (in-repo, master-kernel-build-2021)
    common/                        kernel source (git clone)
    prebuilts-master/clang/host/linux-x86/clang-r416183b/   clang toolchain
    prebuilts/kernel-build-tools/  kernel-build-tools (linux-x86: dtc, openssl, ...)
    prebuilts/build-tools/         hermetic host build tools (linux-x86 + path)
    prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/ gcc host sysroot (in-repo)

Defaults (all overridable via the matching environment variable):

  KERNEL_REPO       Kernel/common source (git clone); must be a full URL or
                    scp-style remote, not a bare owner/repo name
                    https://github.com/CloudFox-INC/CloudFox-Kernel
  CLANG_URL         Clang toolchain (tar.zst); default is the prebuilt
                    release of PREBUILTS_REPO at tag PREBUILTS_TAG,
                    falling back to a sparse clone of the Google ACK
                    platform/prebuilts/clang/host/linux-x86 at
                    CLANG_UPSTREAM_BRANCH
  CLANG_UPSTREAM_NAME  Version directory checked out by that fallback
                    (default: derived from CLANG_ASSET, e.g.
                    clang-r536225-linux-x86.tar.zst -> clang-r536225)
  CLANG_UPSTREAM_BRANCH  Branch holding it (default: android14-dev for
                    clang-r450784e, otherwise ACK_PREBUILTS_BRANCH)
  KBUILD_TOOLS_URL  kernel-build-tools bundle (tar.zst); falls back to a
                    git clone of the AOSP kernel/prebuilts/build-tools at
                    ACK_PREBUILTS_BRANCH
  BUILDTOOLS_URL    hermetic build-tools bundle (tar.zst); falls back to a
                    git clone of AOSP platform/prebuilts/build-tools at
                    ACK_PREBUILTS_BRANCH
  ACK_PREBUILTS_BRANCH  Google ACK branch the prebuilts come from
                    (default: master — clang 19 toolchain; set to
                    master-kernel-build-2021 for the classic clang 14
                    used by android12-5.10 kernels)
  WORK_DIR          Directory for the whole build tree (default: $SCRIPT_DIR/work)
  KERNEL_DIR        Directory name of the kernel source in WORK_DIR (default: common)
  BUILD_CONFIG      Build config to use (default: build.config.cloudfox, which
                    is Google's own build.config.gki.aarch64)
  PREBUILTS_TAG     Release tag holding the prebuilt bundles (default: prebuilts)
  DEFCONFIG_FRAGMENT  Either a directory or a space-separated list of
                     CONFIG_* fragment files appended to the committed
                     gki_defconfig before the build. A directory loads every
                     *.config file it contains, sorted by name, so new
                     fragments are picked up automatically. Default: the
                     per-branch set under $SCRIPT_DIR/build/fragments/<suffix>,
                     resolved from KERNEL_BRANCH (a branch android12-5.10-<x>
                     uses build/fragments/<x>). A branch with no matching set
                     gets no fragments and builds against the stock committed
                     defconfig. The CloudFox
                     self-heal-config stage (POST_DEFCONFIG_CMDS) re-derives
                     the canonical config and rewrites gki_defconfig, so the
                     appended symbols become part of the effective build
                     config. Symbols already carrying the same value are
                     skipped (idempotent re-runs); a different value appends
                     last and wins.
  DEFCONFIG_FRAGMENT_EXCLUDE  Space- or comma-separated fragment names to
                     disable, matched against each fragment file name in
                     full ("metamodule-gki.config"), without the .config
                     suffix ("metamodule-gki"), or by bare core name
                     ("metamodule"). Excluded fragments are skipped even
                     when the set is a directory loaded automatically or an
                     explicit DEFCONFIG_FRAGMENT list.
  GITHUB_TOKEN      If set, used to fetch assets from private prebuilt
                    releases via the GitHub API when the direct download URL
                    is unavailable (automatically set in GitHub Actions)

Options:
  --kernel-repo URL Override KERNEL_REPO
  --kernel-branch B Override KERNEL_BRANCH
  --kernel-commit C Override KERNEL_COMMIT
  --clang-url URL   Override CLANG_URL
  --work-dir DIR    Override WORK_DIR
  --jobs N          Override build parallelism (make -j)
  --defconfig-fragment FILE  Override DEFCONFIG_FRAGMENT
  --defconfig-fragment-exclude NAME  Exclude a fragment by name (repeatable)
  --clean           Remove WORK_DIR before building
  --skip-fetch      Assume the layout already exists, build only
  --skip-build      Fetch/prepare the layout only, do not build
  -h, --help        Show this help
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-repo)   KERNEL_REPO=$2; shift 2 ;;
        --kernel-branch) KERNEL_BRANCH=$2; shift 2 ;;
        --kernel-commit) KERNEL_COMMIT=$2; shift 2 ;;
        --clang-url)     CLANG_URL=$2; shift 2 ;;
        --work-dir)      WORK_DIR=$2; shift 2 ;;
        --jobs|-j)       JOBS=$2; shift 2 ;;
        --defconfig-fragment) DEFCONFIG_FRAGMENT=$2; shift 2 ;;
        --defconfig-fragment-exclude) DEFCONFIG_FRAGMENT_EXCLUDE=${DEFCONFIG_FRAGMENT_EXCLUDE:+$DEFCONFIG_FRAGMENT_EXCLUDE }$2; shift 2 ;;
        --clean)         CLEAN=1; shift ;;
        --ccache)        CCACHE_OPT=1; shift ;;
        --skip-fetch)    SKIP_FETCH=1; shift ;;
        --skip-build)    SKIP_BUILD=1; shift ;;
        -h|--help)       usage 0 ;;
        *)               err "unknown option: $1"; usage 1 ;;
    esac
done

if [ -z "$PREBUILTS_REPO" ]; then
    PREBUILTS_REPO=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)
fi
case "$PREBUILTS_REPO" in
    git@github.com:*)   PREBUILTS_REPO=https://github.com/${PREBUILTS_REPO#git@github.com:} ;;
    git://github.com/*) PREBUILTS_REPO=https://github.com/${PREBUILTS_REPO#git://github.com/} ;;
esac
PREBUILTS_REPO=${PREBUILTS_REPO%.git}
PREBUILTS_REPO=${PREBUILTS_REPO:-https://github.com/CloudFox-INC/CloudFox-Kernel-Builder}
RELEASE_BASE=$PREBUILTS_REPO/releases/download/$PREBUILTS_TAG
REPO_PATH=${PREBUILTS_REPO#https://github.com/}
REPO_PATH=${REPO_PATH#http://github.com/}
REPO_PATH=${REPO_PATH%.git}
API_BASE=https://api.github.com/repos/$REPO_PATH

download_asset() {
    local asset=$1 out=$2 fallback=${3:-} api_url
if [ -z "${GITHUB_TOKEN:-}" ]; then
        curl_dl -fL --retry 3 -sS -o "$out" "$RELEASE_BASE/$asset" && return 0
        [ -n "$fallback" ] && curl_dl -fL --retry 3 -sS -o "$out" "$fallback" && return 0
        return 1
    fi
    if curl_dl -fL --retry 3 -sS -o "$out" "$RELEASE_BASE/$asset" 2>/dev/null; then
        return 0
    fi
    api_url=$(curl_dl -sfL -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
        "$API_BASE/releases/tags/$PREBUILTS_TAG" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    a=[x for x in d.get('assets',[]) if x['name']==sys.argv[1]]
    print(a[0]['url'] if a else '')
except Exception:
    pass
" "$asset" 2>/dev/null || true)
    if [ -n "$api_url" ] && curl_dl -fL --retry 3 -sS \
        -H "Authorization: Bearer ${GITHUB_TOKEN:-}" -H "Accept: application/octet-stream" \
        -o "$out" "$api_url"; then
        return 0
    fi
    [ -n "$fallback" ] && curl_dl -fL --retry 3 -sS -o "$out" "$fallback" && return 0
    return 1
}

preflight() {
    local missing=0 t
    for t in git curl zstd tar which bash sh perl rsync find grep realpath; do
        command -v "$t" >/dev/null 2>&1 || { warn "missing host tool: $t"; missing=1; }
    done
    [ "$missing" -eq 0 ] || die "install the missing tools and re-run"
    # KERNEL_REPO must be a full remote location: a URL with a scheme
    # (https://, git://, ssh://, ...) or an scp-style user@host:path. A bare
    # "owner/repo" is ambiguous and would break the clone.
    case "$KERNEL_REPO" in
        *://*)       : ;;
        *@*:*)       : ;;
        *) die "KERNEL_REPO must be a full URL or scp-style remote (got: '$KERNEL_REPO')" ;;
    esac
}

fetch_build_scripts() {
    if [ -x "$WORK_DIR/build/build.sh" ]; then
        ok "build scripts present at $(rel "$WORK_DIR/build")"
        return
    fi
    rm -rf "${WORK_DIR:?}/build"
    mkdir -p "$WORK_DIR"
    if [ -x "$SCRIPT_DIR/build/build.sh" ]; then
        cp -a "$SCRIPT_DIR/build" "$WORK_DIR/build"
    else
        die "in-repo build scripts missing at $SCRIPT_DIR/build"
    fi
    ok "build scripts copied from repo (Google kernel build, unmodified)"
}

fetch_kernel() {
    if [ -d "$WORK_DIR/$KERNEL_DIR/.git" ]; then
        ok "kernel source present at $(rel "$WORK_DIR/$KERNEL_DIR")"
        return
    fi
    rm -rf "${WORK_DIR:?}/${KERNEL_DIR:?}"
    if [ -n "$KERNEL_COMMIT" ]; then
        git init -q "$WORK_DIR/$KERNEL_DIR"
        git -C "$WORK_DIR/$KERNEL_DIR" remote add origin "$KERNEL_REPO"
        git -C "$WORK_DIR/$KERNEL_DIR" fetch -q --depth 1 origin "$KERNEL_COMMIT"
        git -C "$WORK_DIR/$KERNEL_DIR" checkout -q FETCH_HEAD
    else
        local args=(clone -q --depth 1)
        [ -z "$KERNEL_BRANCH" ] || args+=(-b "$KERNEL_BRANCH")
        git "${args[@]}" "$KERNEL_REPO" "$WORK_DIR/$KERNEL_DIR"
    fi
    ok "kernel source cloned"
}

resolve_clang_dir() {
    local dir found
    for dir in "$WORK_DIR/prebuilts-master/clang/host/linux-x86" \
               "$WORK_DIR/prebuilts/clang/host/linux-x86" \
               "$WORK_DIR"; do
        # On a fresh runner the kernel clone, build output and download
        # staging all live under WORK_DIR and are huge; clang never lives in
        # them, so prune them from the fallback scan instead of walking them.
        found=$(find "$dir" \
            \( -path "$WORK_DIR/$KERNEL_DIR" -o -path "$WORK_DIR/out" \
               -o -path "$WORK_DIR/downloads" -o -path "$WORK_DIR/build" \
               -o -path "$WORK_DIR/dist" \) -prune -o \
            -maxdepth 8 -path '*/bin/clang' -executable -print -quit 2>/dev/null || true)
        [ -n "$found" ] || continue
        printf '%s\n' "${found%/bin/clang}"
        return 0
    done
    return 1
}

fetch_clang_download() {
    # Download-only half of fetch_clang, safe to run in parallel with the
    # kernel clone: the tarball download does not need the kernel tree (only
    # fetch_clang's final CLANG_PREBUILT_BIN symlink does). Writes to a .part
    # temp and renames on success so a partial file is never mistaken for a
    # completed download.
    local tarball=$WORK_DIR/downloads/clang.tar.zst
    local clang_dir
    clang_dir=$(resolve_clang_dir || true)
    [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] && return 0
    [ -s "$tarball" ] && return 0
    mkdir -p "$WORK_DIR/downloads"
    if [ -n "$CLANG_URL" ]; then
        curl_dl -fL --retry 3 -sS -o "$tarball.part" "$CLANG_URL" || { rm -f "$tarball.part"; return 1; }
    else
        download_asset "$CLANG_ASSET" "$tarball.part" || { rm -f "$tarball.part"; return 1; }
    fi
    mv -f "$tarball.part" "$tarball"
    ok "clang tarball downloaded"
}

fetch_clang_extract() {
    # Extraction-only half of fetch_clang: unpacks the tarball downloaded by
    # fetch_clang_download. It touches only the prebuilts tree, never the
    # kernel tree, so it can overlap the kernel clone (only fetch_clang's
    # pin-symlink step reads build.config.common from the kernel).
    local root=$WORK_DIR/prebuilts-master/clang/host/linux-x86
    local tarball=$WORK_DIR/downloads/clang.tar.zst
    local clang_dir
    clang_dir=$(resolve_clang_dir || true)
    [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] && return 0
    [ -s "$tarball" ] || return 0
    mkdir -p "$root"
    tar -I 'zstd -T0' -xf "$tarball" -C "$root"
    clang_dir=$(resolve_clang_dir || true)
    [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] || return 1
    ok "clang toolchain ready at $(rel "$clang_dir")"
}

fetch_clang() {
    local root=$WORK_DIR/prebuilts-master/clang/host/linux-x86
    local tarball=$WORK_DIR/downloads/clang.tar.zst
    local pin pin_dir clang_dir
    pin=$(config_get "$WORK_DIR/$KERNEL_DIR/build.config.common" CLANG_PREBUILT_BIN)
    case "$pin" in
        */bin) pin_dir=${pin%/bin} ;;
        *)     pin_dir=$pin ;;
    esac
    mkdir -p "$root"
    clang_dir=$(resolve_clang_dir || true)
    if [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ]; then
        ok "clang toolchain present at $(rel "$clang_dir")"
    else
        # The tarball extraction normally already ran in parallel with the
        # kernel clone (fetch_clang_extract); these branches cover the
        # fallbacks when there was no tarball to extract (download failed) or
        # fetch_clang is called standalone.
        if [ -s "$tarball" ]; then
            tar -I 'zstd -T0' -xf "$tarball" -C "$root"
        elif [ -n "$CLANG_URL" ]; then
            curl_dl -fL --retry 3 -o "$tarball" "$CLANG_URL" || die "failed to download clang from $CLANG_URL"
            tar -I 'zstd -T0' -xf "$tarball" -C "$root"
        elif ! download_asset "$CLANG_ASSET" "$tarball"; then
            warn "no prebuilt clang bundle, sparse-cloning $CLANG_UPSTREAM_NAME from $CLANG_UPSTREAM_REPO (branch $CLANG_UPSTREAM_BRANCH)"
            warn "this pulls several GB; run the prebuilts workflow to publish $CLANG_ASSET and make future builds fast"
            rm -rf "$root"
            git clone -q --depth 1 --filter=blob:none --sparse \
                -b "$CLANG_UPSTREAM_BRANCH" "$CLANG_UPSTREAM_REPO" "$root" \
                || { rm -rf "$root"; git clone -q --depth 1 -b "$CLANG_UPSTREAM_BRANCH" "$CLANG_UPSTREAM_REPO" "$root"; }
            # Check out the upstream version directory, not the alias pinned by
            # build.config.common: the pinned name (e.g. clang-r416183b) is not
            # present upstream, so asking for it yields an empty tree and the
            # build only fails later with a confusing "no usable clang".
            git -C "$root" sparse-checkout set "$CLANG_UPSTREAM_NAME"
            [ -x "$root/$CLANG_UPSTREAM_NAME/bin/clang" ] \
                || die "sparse checkout of $CLANG_UPSTREAM_NAME produced no clang binary; check that branch $CLANG_UPSTREAM_BRANCH of $CLANG_UPSTREAM_REPO still carries it (override with CLANG_UPSTREAM_NAME/CLANG_UPSTREAM_BRANCH, or CLANG_URL for a direct tarball)"
        else
            tar -I 'zstd -T0' -xf "$tarball" -C "$root"
        fi
        clang_dir=$(resolve_clang_dir || true)
        [ -n "$clang_dir" ] && [ -x "$clang_dir/bin/clang" ] || die "no usable clang toolchain anywhere under $(rel "$WORK_DIR") (expected under $(rel "$root"))"
        ok "clang toolchain ready at $(rel "$clang_dir")"
    fi
    if [ -n "$pin" ] && [ -x "$WORK_DIR/$pin_dir/bin/clang" ]; then
        ok "clang path pinned by build.config.common resolves"
    elif [ -n "$pin" ] && [ -n "$clang_dir" ]; then
        ln -sfnT "$clang_dir" "$WORK_DIR/$pin_dir"
        ok "linked clang toolchain to the pinned path (build.config.common)"
    fi
}

fetch_ccache() {
    # Install the prebuilt ccache binary. Runs inside the parallel fetch pool
    # so it overlaps the heavy prebuilt downloads instead of serializing as a
    # separate workflow step. Nothing here is fatal: install_ccache_wrappers
    # no-ops (and the build proceeds un-cached) if ccache is unavailable.
    command -v ccache >/dev/null 2>&1 && return 0
    local arch
    arch=$(uname -m)
    [ "$arch" = "x86_64" ] || { warn "ccache: unsupported arch '$arch'; skipping"; return 0; }
    local ver=4.13.6
    local tmp="$WORK_DIR/downloads/ccache.tar.xz"
    mkdir -p "$WORK_DIR/downloads"
    curl_dl -fL --retry 3 -sS -o "$tmp" \
        "https://github.com/ccache/ccache/releases/download/v${ver}/ccache-${ver}-linux-x86_64-glibc.tar.xz" \
        || { warn "ccache: download failed; building without ccache"; return 0; }
    local tree
    tree=$(mktemp -d)
    tar -xJf "$tmp" -C "$tree" --strip-components=1 \
        && sudo install -m 0755 "$tree/ccache" /usr/local/bin/ccache
    rm -rf "$tree"
    command -v ccache >/dev/null 2>&1 || warn "ccache: install incomplete; building without ccache"
}

install_ccache_wrappers() {
    # ccache-accelerate the kernel compile. build.sh sets LLVM=1 (forcing
    # "CC=clang" in its LLVM branch) and prepends CLANG_PREBUILT_BIN to PATH, so
    # neither a CC="ccache clang" make arg nor ccache PATH symlinks survive.
    # The one injection point that does is the compiler binary itself. In
    # Android clang builds the real compilers live as "bin/<tool>.real" invoked
    # by a Go compiler-wrapper "bin/<tool>"; relocating those wrappers breaks
    # their sibling-.real lookup, so we wrap the ".real" file in place instead
    # (falling back to wrapping "bin/<tool>" directly for plain single binaries).
    # Every compiler invocation funnels through ccache, and it is fully
    # reversible: the real binaries are preserved and restored on exit, so a
    # ccache failure cannot poison the toolchain.
    [ -n "${CCACHE_OPT:-}" ] || return 0
    [ -n "${CCACHE_WRAPPED:-}" ] && return 0   # already wrapped (idempotent)
    local ccache_bin
    ccache_bin=$(command -v ccache) || { warn "ccache requested but not installed; skipping wrap"; CCACHE_OPT=; return 0; }
    local clang_dir
    clang_dir=$(resolve_clang_dir || true)
    if [ -z "$clang_dir" ] || [ ! -x "$clang_dir/bin/clang" ]; then
        warn "ccache: no clang toolchain to wrap"; CCACHE_OPT=; return 0
    fi
    # build.sh runs with a hermetic PATH that excludes /usr/local/bin, so the
    # launchers must call ccache by absolute path (bare "exec ccache" would 127).
    "$ccache_bin" -o cache_dir="$WORK_DIR/.ccache" >/dev/null 2>&1 || true
    mkdir -p "$WORK_DIR/.ccache" "$clang_dir/.cfx-orig-bin"
    local tool target orig realbin
    for tool in clang clang++ ${CCACHE_LINK_TOOLS:-aarch64-linux-gnu-clang aarch64-linux-gnu-clang++}; do
        target="$clang_dir/bin/$tool"
        [ -x "$target.real" ] && target="$target.real"   # Go-wrapper toolchain
        [ -e "$target" ] || [ -L "$target" ] || continue
        # If the real compiler is a symlink, resolve its absolute target NOW
        # (relocating the symlink would dangle it); feed ccache the resolved
        # genuine binary. For a plain file we feed the relocated copy instead.
        realbin=
        [ -L "$target" ] && realbin=$(readlink -f -- "$target" 2>/dev/null)
        orig="$clang_dir/.cfx-orig-bin/$(basename -- "$target")"
        if [ ! -e "$orig" ] && [ ! -L "$orig" ]; then
            mv -- "$target" "$orig"
        fi
        [ -n "$realbin" ] || realbin="$orig"
        [ -x "$realbin" ] || continue
        rm -f -- "$target"
        cat > "$target" <<EOF
#!/usr/bin/env bash
exec "$ccache_bin" "$realbin" "\$@"
EOF
        chmod +x "$target"
    done
    # CCACHE_* sizing/tuning (mirrors the approach used by the OnePlus KSU kernel
    # workflow). The critical ones for kernel reuse: IGNOREOPTIONS drops the
    # Android --sysroot=<build-tree path> (which changes per run and would bust
    # every hit), DIRECT+DEPEND skip preprocessor re-runs, and COMPRESSION makes
    # the on-disk cache smaller/faster to upload+restore across CI runs.
    export CCACHE_COMPILERCHECK=content
    export CCACHE_NOHASHDIR=true
    export CCACHE_BASEDIR="$WORK_DIR"
    export CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime,pch_defines,system_headers,locale
    export CCACHE_IGNOREOPTIONS=--sysroot*
    export CCACHE_DIRECT=true
    export CCACHE_COMPRESSION=true
    export CCACHE_COMPRESSION_LEVEL=1
    export CCACHE_MAXSIZE=12G
    export CCACHE_DIR="$WORK_DIR/.ccache"
    # depend mode (4.1+) stores dependency data so unchanged files hit without a
    # full re-preprocess; enable opportunistically.
    if "$ccache_bin" --help 2>&1 | grep -qi 'depend'; then
        export CCACHE_DEPEND=true
    fi
    CCACHE_WRAPPED=1
    info "ccache wrappers installed on $(rel "$clang_dir") toolchain (CCACHE_DIR=$(rel "$CCACHE_DIR"))"
}
restore_ccache_wrappers() {
    [ -n "${CCACHE_OPT:-}" ] || return 0
    local clang_dir=$(resolve_clang_dir || true)
    [ -z "$clang_dir" ] || [ ! -d "$clang_dir/.cfx-orig-bin" ] && return 0
    local f
    for f in "$clang_dir/.cfx-orig-bin/"*; do
        [ -e "$f" ] || continue
        mv -f -- "$f" "$clang_dir/bin/$(basename -- "$f")"
    done
    rm -rf "$clang_dir/.cfx-orig-bin"
}

# Populate a prebuilt tree at $dest: prefer an explicit URL tarball, then the
# PREBUILTS_TAG release asset, then a shallow clone of the upstream repo.
# Remaining args after <upstream_repo> are sparse-checkout paths (cone mode);
# when given, the clone only fetches those subtrees instead of the whole
# multi-GB repo (build-tools carries darwin-x86/windows payloads the kernel
# build never reads). Falls back to a full clone if the server rejects
# blob:none filtering.
fetch_prebuilt_tree() { # <dest> <tarball> <url> <asset> <upstream_repo> [sparse dirs...]
    local dest=$1 tarball=$2 url=$3 asset=$4 upstream=$5; shift 5
    local -a sparse=("$@")
    rm -rf "$dest"
    mkdir -p "$dest"
    if [ -z "$url" ]; then
        if download_asset "$asset" "$tarball"; then
            tar -I 'zstd -T0' -xf "$tarball" -C "$dest"
        else
            warn "no prebuilt bundle, cloning $upstream"
            if [ "${#sparse[@]}" -gt 0 ]; then
                git clone -q --depth 1 --filter=blob:none --sparse \
                    -b "$ACK_PREBUILTS_BRANCH" "$upstream" "$dest" \
                    && git -C "$dest" sparse-checkout set "${sparse[@]}" \
                    || { rm -rf "$dest"; git clone -q --depth 1 -b "$ACK_PREBUILTS_BRANCH" "$upstream" "$dest"; }
            else
                git clone -q --depth 1 -b "$ACK_PREBUILTS_BRANCH" "$upstream" "$dest"
            fi
        fi
    else
        curl_dl -fL --retry 3 -o "$tarball" "$url"
        tar -I 'zstd -T0' -xf "$tarball" -C "$dest"
    fi
}

fetch_kernel_build_tools() {
    local kbt=$WORK_DIR/prebuilts/kernel-build-tools
    local tarball=$WORK_DIR/downloads/kernel-build-tools.tar.zst
    if [ -x "$kbt/linux-x86/bin/dtc" ]; then
        ok "kernel-build-tools present"
        return
    fi
    fetch_prebuilt_tree "$kbt" "$tarball" "$KBUILD_TOOLS_URL" "$KBUILD_TOOLS_ASSET" "$KBUILD_TOOLS_UPSTREAM_REPO" linux-x86
    [ -x "$kbt/linux-x86/bin/dtc" ] || die "kernel-build-tools missing linux-x86/bin/dtc"
    ok "kernel-build-tools ready"
}

fetch_build_tools() {
    local bt=$WORK_DIR/prebuilts/build-tools
    local tarball=$WORK_DIR/downloads/build-tools.tar.zst
    if [ -x "$bt/linux-x86/bin/make" ] && [ -x "$bt/path/linux-x86/python3" ]; then
        ok "build-tools present"
        return
    fi
    fetch_prebuilt_tree "$bt" "$tarball" "$BUILDTOOLS_URL" "$BUILDTOOLS_ASSET" "$BUILDTOOLS_UPSTREAM_REPO" linux-x86 path/linux-x86 common/bison
    [ -x "$bt/linux-x86/bin/make" ] || die "build-tools missing linux-x86/bin/make"
    [ -x "$bt/path/linux-x86/python3" ] || die "build-tools missing path/linux-x86/python3"
    ok "build-tools ready"
}

fetch_gcc_host() {
    local gcc_root=$WORK_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8
    if [ -d "$gcc_root/sysroot" ]; then
        ok "gcc host sysroot present"
        return
    fi
    rm -rf "${gcc_root:?}"
    mkdir -p "$gcc_root"
    if [ -d "$SCRIPT_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot" ]; then
        cp -a "$SCRIPT_DIR/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot" "$gcc_root/"
    else
        warn "sysroot not in repo, sparse-cloning $GCC_HOST_UPSTREAM_REPO"
        git clone -q --depth 1 --filter=blob:none --sparse "$GCC_HOST_UPSTREAM_REPO" "$gcc_root" 2>/dev/null \
            || git clone -q --depth 1 "$GCC_HOST_UPSTREAM_REPO" "$gcc_root"
        git -C "$gcc_root" sparse-checkout set sysroot
    fi
    [ -d "$gcc_root/sysroot" ] || die "gcc host sysroot missing"
    ok "gcc host sysroot ready"
}

fetch_gas() {
    [ -z "$GAS_URL" ] && return
    local gas=$WORK_DIR/prebuilts/gas/linux-x86
    [ -d "$gas/.git" ] && return
    git clone -q --depth 1 "$GAS_URL" "$gas"
    ok "gas prebuilt ready"
}

verify_build_tools_links() {
    local farm=$WORK_DIR/build/build-tools/path/linux-x86
    if [ ! -d "$farm" ]; then
        warn "no symlink farm at $farm (build scripts too old/new for this layout?)"
        return
    fi
    local broken=0 n=0 f
    for f in "$farm"/*; do
        n=$((n + 1))
        if [ -L "$f" ]; then
            [ -e "$f" ] || { warn "unresolved build tool link: $(basename "$f")"; broken=1; }
        elif [ ! -e "$f" ]; then
            warn "not a symlink and not a file: $f"
            broken=1
        fi
    done
    if [ "$broken" -eq 0 ]; then
        ok "build-tools symlink farm resolves ($n tools)"
    else
        warn "some hermetic build tools are unresolved; the build may fail if they are used"
    fi
}

write_build_config() {
    cat > "$WORK_DIR/build.config.cloudfox" <<EOF
# CloudFox build config: based on Google's GKI aarch64 build config
# (which sources build.config.common + build.config.aarch64 + build.config.gki).
export KERNEL_DIR=$KERNEL_DIR
. \${ROOT_DIR}/\${KERNEL_DIR}/build.config.gki.aarch64

# CloudFox addition: replace the stock check_defconfig hook with a
# self-healing defconfig stage. It verifies the resolved config against the
# committed gki_defconfig, repairs it when stale, and re-derives the effective
# config until convergence. Runs in build.sh's env (ARCH, O=, LLVM, LLVM_IAS).
export POST_DEFCONFIG_CMDS="\${ROOT_DIR}/build/self-heal-config.sh"
EOF

    if [ -n "$CLANG_URL" ]; then
        cat >> "$WORK_DIR/build.config.cloudfox" <<'EOF'

# CloudFox addition (bare-metal-only toolchain, e.g. Neutron via CLANG_URL):
# the custom clang cross-compiles the kernel but ships NO host/userspace
# runtime, so host tools (fixdep, kallsyms, kconfig, ...) it builds die with
# SIGSEGV when executed on the runner (HOSTCC was forced to clang by LLVM=1).
# Two fixes, both local to this config so regular ACK runs are untouched:
#  1. HERMETIC_TOOLCHAIN=0: the hermetic stage both gutted PATH (removing the
#     host gcc) and injected clang-only flags (--sysroot, --rtlib=compiler-rt)
#     into HOSTCFLAGS/HOSTLDFLAGS. With it off, host tools build with the
#     plain system compiler.
#  2. CLOUDFOX_HOST_CC/CXX: consumed by self-heal-config.sh to run its own
#     `make` with the same HOSTCC/HOSTCXX override (build.sh's LLVM branch
#     locally resets HOSTCC=clang, which must not leak into self-heal's make).
# The actual HOSTCC/HOSTCXX make override for build.sh is passed by
# build-kernel.sh as command-line args (see run_build), because build.sh's
# LLVM branch hard-codes HOSTCC=clang in TOOL_ARGS.
export HERMETIC_TOOLCHAIN=0
export CLOUDFOX_HOST_CC=${CLOUDFOX_HOST_CC:-gcc}
export CLOUDFOX_HOST_CXX=${CLOUDFOX_HOST_CXX:-g++}
EOF
        ok "custom-toolchain host-tool override appended"
    fi

    # APPEND_BUILD_ENV: comma-separated "KEY=VALUE" pairs written as export
    # lines so build.sh (which sources this config) sees them. Example:
    # TRIM_UNUSED_KSYMS=1,LOCALVERSION="-vanilla"
    if [ -n "$APPEND_BUILD_ENV" ]; then
        local IFS=, pair
        {
            printf '\n# CloudFox addition: caller-appended build env (sourced by build.sh)\n'
            for pair in $APPEND_BUILD_ENV; do
                [ -n "$pair" ] && printf 'export %s\n' "$pair"
            done
        } >> "$WORK_DIR/build.config.cloudfox"
        ok "caller build env appended"
    fi
}

# Resolve the default defconfig-fragment directory from the kernel branch name.
# Branches are android12-5.10-<suffix>; the matching fragment set lives in
# $SCRIPT_DIR/build/fragments/<suffix>/. An empty KERNEL_BRANCH falls back to
# the branch actually checked out by the clone (fetch_kernel clones the repo's
# default branch when none is given), so the fragment set follows the real
# branch instead of silently building the stock defconfig. A branch with no
# matching set (or not an android12-5.10- build at all) falls back to the
# shared default set $SCRIPT_DIR/build/fragments/default/ (modskip, metamodule,
# zram). A branch that resolves to neither yields no fragments and the kernel
# builds against the stock committed defconfig. An explicit DEFCONFIG_FRAGMENT
# is always honored as-is.
resolve_fragment_dir() {
    local branch=$KERNEL_BRANCH suffix frag_dir
    if [ -z "$branch" ]; then
        branch=$(git -C "$WORK_DIR/$KERNEL_DIR" branch --show-current 2>/dev/null || true)
        [ -n "$branch" ] && info "KERNEL_BRANCH empty; resolved from clone: $branch" >&2
    fi
    if [ -n "$branch" ] && [ "${branch#android12-5.10-}" != "$branch" ]; then
        suffix=${branch#android12-5.10-}
        frag_dir=$SCRIPT_DIR/build/fragments/$suffix
        if [ -d "$frag_dir" ]; then
            printf '%s\n' "$frag_dir"
            return 0
        fi
    fi
    if [ -d "$SCRIPT_DIR/build/fragments/default" ]; then
        [ -n "$branch" ] && warn "no CloudFox fragment set for branch '$branch'; falling back to default fragments"
        printf '%s\n' "$SCRIPT_DIR/build/fragments/default"
    else
        [ -n "$branch" ] && warn "no CloudFox fragment set for branch '$branch'; building with stock defconfig"
    fi
}

apply_defconfig_fragment() {
    # If the caller set DEFCONFIG_FRAGMENT to a list of files, honor it as-is.
    # A directory means "auto-load every *.config in it, sorted", so new
    # fragments are picked up automatically without edits here. Otherwise the
    # per-branch directory is resolved from KERNEL_BRANCH
    # (build/fragments/<branch suffix>); a branch with no fragment set yields
    # nothing and the kernel builds against the stock committed defconfig.
    local frags=${DEFCONFIG_FRAGMENT:-}
    [ -n "$frags" ] || frags=$(resolve_fragment_dir)
    if [ -d "$frags" ]; then
        frags=$(shopt -s nullglob; printf '%s\n' "$frags"/*.config | sort -d)
    fi
    # Drop fragments listed in DEFCONFIG_FRAGMENT_EXCLUDE. Each name matches a
    # fragment file's base name in full ("modskip-gki.config"), without the
    # .config suffix ("modskip-gki"), or by bare core name ("modskip"). A plain
    # array loop (no pipeline) also keeps `set -euo pipefail` from aborting
    # when the exclusions empty the set.
    if [ -n "$DEFCONFIG_FRAGMENT_EXCLUDE" ]; then
        local excl=${DEFCONFIG_FRAGMENT_EXCLUDE//,/ }
        local -a keep=()
        local frag name core drop e
        for frag in $frags; do
            [ -z "$frag" ] && continue
            name=$(basename "$frag")
            core=${name%.config}
            core=${core%-*}
            drop=
            for e in $excl; do
                if [ "$name" = "$e" ] || [ "${name%.config}" = "$e" ] || [ "$core" = "$e" ]; then
                    drop=1
                    break
                fi
            done
            if [ -n "$drop" ]; then
                warn "defconfig fragment excluded: $name"
            else
                keep+=("$frag")
            fi
        done
        frags=${keep[*]}
    fi
    [ -n "$frags" ] || return 0

    local cfg=$WORK_DIR/build.config.cloudfox
    local arch defconfig
    arch=$(config_get "$cfg" ARCH)
    defconfig=$(config_get "$cfg" DEFCONFIG)
    arch=${arch:-arm64}
    defconfig=${defconfig:-gki_defconfig}
    local file=$WORK_DIR/$KERNEL_DIR/arch/$arch/configs/$defconfig
    [ -f "$file" ] || die "defconfig not found: $file (defconfig fragment(s) not applied)"

    # APPEND_CONFIG: comma-separated literal CONFIG_* lines injected into the
    # defconfig on top of the resolved fragment set (e.g. CONFIG_KERNELSU=y).
    # Collected into a temp file treated as one extra fragment so the lines go
    # through the same per-symbol dedup and append machinery below.
    if [ -n "$APPEND_CONFIG" ]; then
        local lcf ap ifs_save
        lcf=$(mktemp)
        ifs_save=$IFS
        IFS=,
        for ap in $APPEND_CONFIG; do
            [ -n "$ap" ] || continue
            case "$ap" in
                CONFIG_*=*|'# CONFIG_'*' is not set')
                    printf '%s\n' "$ap" >> "$lcf" ;;
                *)
                    warn "append_config must be literal CONFIG_* lines; ignoring: $ap" ;;
            esac
        done
        IFS=$ifs_save
        if [ -s "$lcf" ]; then
            frags="$frags $lcf"
        else
            rm -f "$lcf"
        fi
    fi

    local start='# begin-cloudfox-fragment' end='# end-cloudfox-fragment'
    local stripped block out sym val cand line frag bad
    stripped=$(mktemp)
    block=$(mktemp)
    out=$(mktemp)
    awk -v s="$start" -v e="$end" '$0==s{skip=1;next} $0==e{skip=0;next} !skip' "$file" > "$stripped"

    # Index the defconfig's effective symbol lines once; per-symbol membership
    # checks below then avoid re-scanning the whole file with one grep fork each.
    local -A cfg
    while IFS= read -r line; do
        case "$line" in
            CONFIG_*=*|'# CONFIG_'*' is not set') cfg["$line"]=1 ;;
        esac
    done < "$file"

    {
        printf '\n%s\n' "$start"
        for frag in $frags; do
            [ -f "$frag" ] || die "defconfig fragment not found: $frag"
            bad=$(grep -nEv '^[[:space:]]*(#|$)|^CONFIG_' "$frag" || true)
            [ -z "$bad" ] || die "invalid lines in defconfig fragment \"$frag\":$(printf '\n%s' "$bad")"
            printf '# fragment: %s\n' "$frag"
            while IFS= read -r line; do
                case "$line" in
                    *' is not set') sym=${line#\# }; sym=${sym%' is not set'}; val= ;;
                    ''|'#'*)    continue ;;
                    CONFIG_*=*) sym=${line%%=*}; val=${line#*=} ;;
                    *) continue ;;
                esac
                if [ -n "$val" ]; then
                    cand="${sym}=${val}"
                else
                    cand="# ${sym} is not set"
                fi
                [[ -v "cfg[$cand]" ]] && continue
                printf '%s\n' "$line"
            done < "$frag"
        done
        printf '%s\n' "$end"
    } > "$block"

    if grep -qE '^CONFIG_|^# CONFIG_' "$block"; then
        cat "$stripped" "$block" > "$out"
        mv "$out" "$file"
        ok "appended defconfig fragment(s) to $(rel "$file")"
        commit_defconfig "$arch" "$defconfig" "apply CloudFox defconfig fragments"
    else
        ok "defconfig fragment(s): all symbols already effective, defconfig unchanged"
        rm -f "$out"
    fi
    rm -f "$stripped" "$block"
}

# Commit a defconfig we just modified inside the kernel tree, so the kernel
# version string does not gain a -dirty suffix (scripts/setlocalversion flags
# any uncommitted tree change). Non-fatal: the build still proceeds if the
# tree is not a git repo or the commit cannot be made.
commit_defconfig() { # <arch> <defconfig> <message>
    local arch=$1 defconfig=$2 msg=$3
    local tree=$WORK_DIR/$KERNEL_DIR
    [ -d "$tree/.git" ] || { warn "kernel tree is not a git repo; $defconfig left uncommitted (kernel version may carry -dirty)"; return 0; }
    if git -C "$tree" -c user.name="${GIT_BUILDER_NAME:-CloudFox Kernel Builder}" \
            -c user.email="${GIT_BUILDER_EMAIL:-builder@localhost}" \
            commit -q --only -m "$msg: $defconfig" -- \
            "arch/$arch/configs/$defconfig" 2>/dev/null; then
        ok "committed $defconfig ($msg)"
    else
        warn "could not commit $defconfig; kernel version may carry -dirty"
    fi
}

run_build() {
    local config=${BUILD_CONFIG:-build.config.cloudfox}
    if [ -z "$BUILD_CONFIG" ]; then
        info "build config: $(rel "$WORK_DIR/build.config.cloudfox") (Google's build.config.gki.aarch64)"
    else
        info "build config: $config"
        [ -f "$WORK_DIR/$config" ] || die "build config not found: $WORK_DIR/$config"
    fi
    [ -n "$JOBS" ] && export MAKEFLAGS="-j$JOBS"
    # Bare-metal-only toolchains (CLANG_URL) cannot build host tools; make is
    # forced to HOSTCC=clang by the kernel's LLVM=1, producing host binaries
    # that SIGSEGV at runtime. Pass an explicit host compiler as a make
    # command-line variable (overrides the Makefile's `HOSTCC = clang`).
    local host_args=()
    if [ -n "$CLANG_URL" ]; then
        host_args+=(
            "HOSTCC=${CLOUDFOX_HOST_CC:-gcc}"
            "HOSTCXX=${CLOUDFOX_HOST_CXX:-g++}"
            "HOSTLD=ld"
            "HOSTAR=ar"
        )
        info "host tools will use ${CLOUDFOX_HOST_CC:-gcc} (custom toolchain has no host runtime)"
    fi
    (cd "$WORK_DIR" && BUILD_CONFIG=$config ./build/build.sh "${host_args[@]}")
}

collect() {
    local dist_out config_out
    dist_out=$(find "$WORK_DIR/out" -maxdepth 4 -type d -name dist -print -quit 2>/dev/null || true)
    [ -n "$dist_out" ] || { warn "no dist dir under $WORK_DIR/out"; return; }
    local dist_dir=$WORK_DIR/dist
    rm -rf "$dist_dir"
    mv "$dist_out" "$dist_dir"
    if [ -f "$dist_dir/arch/arm64/boot/Image" ]; then
        if bash "$WORK_DIR/$KERNEL_DIR/scripts/extract-ikconfig" "$dist_dir/arch/arm64/boot/Image" > "$dist_dir/ikconfig" 2>/dev/null; then
            ok "ikconfig extracted (embedded kernel config)"
        else
            warn "ikconfig extraction failed (is CONFIG_IKCONFIG enabled?)"
        fi
    fi
    config_out=$(find "$WORK_DIR/out" -maxdepth 3 -name .config -print -quit 2>/dev/null || true)
    [ -z "$config_out" ] || cp -a "$config_out" "$dist_dir/.config"
    ok "artifacts collected in $(rel "$dist_dir")"
}

main() {
    [ "$(readlink -f "$WORK_DIR")" != "$(readlink -f "$SCRIPT_DIR")" ] \
        || die "WORK_DIR must not be the script directory (use the default $SCRIPT_DIR/work)"
    if [ "$CLEAN" -eq 1 ]; then
        rm -rf "$WORK_DIR"
    fi
    mkdir -p "$WORK_DIR/downloads"
    info "work dir: $(rel "$WORK_DIR")"
    info "prebuilt release base: $RELEASE_BASE"
    preflight
    if [ "$SKIP_FETCH" -eq 0 ]; then
        fetch_build_scripts
        # Only fetch_clang depends on the kernel tree (it reads the
        # CLANG_PREBUILT_BIN pin from build.config.common), so it waits for the
        # kernel clone; kernel-build-tools/build-tools/gcc/gas are independent
        # and network-bound, so they overlap the clone instead of serializing
        # every ~GB on a fresh CI runner.
        local kernel_pid fetch_pids=() fetch_rc=0 pid clang_dl_pid
        fetch_kernel & kernel_pid=$!
        fetch_kernel_build_tools & fetch_pids+=("$!")
        fetch_build_tools & fetch_pids+=("$!")
        # The gcc host sysroot is consumed only by the hermetic build stage
        # (_setup_env.sh --sysroot=build/build-tools/sysroot). It is skipped
        # when the hermetic stage is disabled: CLANG_URL forces
        # HERMETIC_TOOLCHAIN=0 in the build config (custom toolchains), and an
        # explicit HERMETIC_TOOLCHAIN=0 disables it directly - in both cases
        # avoid the ~1GB sparse clone of a sysroot nothing will reference.
        if [ -z "$CLANG_URL" ] && [ "${HERMETIC_TOOLCHAIN:-1}" != "0" ]; then
            fetch_gcc_host & fetch_pids+=("$!")
        fi
        fetch_gas & fetch_pids+=("$!")
        # ccache is just a small prebuilt binary; fetching it here overlaps the
        # multi-GB prebuilts instead of serializing as a workflow step. Falls
        # back gracefully (wrap then no-ops) if the download fails.
        fetch_ccache & fetch_pids+=("$!")
        # The clang tarball download and its zstd extraction only read
        # CLANG_URL/release assets, never the kernel tree (fetch_clang's pin
        # symlink needs the kernel), so both overlap the clone instead of
        # serializing the ~1GB transfer and its decompression behind it.
        fetch_clang_download && fetch_clang_extract & clang_dl_pid=$!
        # Wait out the clang download/extract before branching; it must complete
        # before fetch_clang runs regardless of the clone's outcome.
        wait "$clang_dl_pid" || true
        if wait "$kernel_pid"; then
            fetch_clang & fetch_pids+=("$!")
        else
            fetch_rc=1
        fi
        for pid in "${fetch_pids[@]}"; do
            wait "$pid" || fetch_rc=1
        done
        [ "$fetch_rc" -eq 0 ] || die "one or more prebuilt fetches failed"
        verify_build_tools_links
        write_build_config
    else
        [ -x "$WORK_DIR/build/build.sh" ] || die "--skip-fetch requires an existing layout in $WORK_DIR"
    fi
    apply_defconfig_fragment
    if [ "$SKIP_BUILD" -eq 0 ]; then
        # ccache binary is fetched in the parallel pool above and ccache itself
        # comes on line only after the pool wait; wrap clang now that both are
        # guaranteed. Also covers --skip-fetch (clang pre-dates this run).
        # Always restore the toolchain binaries, even on build failure.
        install_ccache_wrappers
        trap restore_ccache_wrappers EXIT
        run_build
        collect
        info "done. kernel and artifacts: $(rel "$WORK_DIR/dist")"
    else
        info "fetch phase done; layout ready in $(rel "$WORK_DIR") (run again without --skip-build)"
    fi
}

main "$@"
