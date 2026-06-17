#!/usr/bin/env bash
# Fetch + build LAME 3.100 for every Android ABI and drop the resulting
# libmp3lame.so under android/src/main/jniLibs/<abi>/.
#
# Requirements: curl, tar, Android NDK on PATH (ANDROID_NDK_HOME or NDK_ROOT).
# Run once: ./android/scripts/fetch_lame.sh [api]   (api defaults to 23).
#
# After this script finishes, LameStub.isAvailable() flips true on the next
# Gradle build and Recorder.start(format: "mp3") records end-to-end.

set -euo pipefail

API="${1:-23}"
NDK="${ANDROID_NDK_HOME:-${NDK_ROOT:-}}"
if [[ -z "${NDK}" || ! -d "${NDK}" ]]; then
    echo "ERROR: set ANDROID_NDK_HOME or NDK_ROOT to your installed NDK" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JNI_LIBS="${ROOT}/android/src/main/jniLibs"
WORK="${ROOT}/android/.lame-build"
LAME_VERSION="3.100"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"
LAME_TARBALL="${WORK}/lame-${LAME_VERSION}.tar.gz"
LAME_SRC="${WORK}/lame-${LAME_VERSION}"

mkdir -p "${WORK}" "${JNI_LIBS}"

if [[ ! -f "${LAME_TARBALL}" ]]; then
    echo ">> fetching LAME ${LAME_VERSION}"
    curl -fsSL "${LAME_URL}" -o "${LAME_TARBALL}"
fi

if [[ ! -d "${LAME_SRC}" ]]; then
    echo ">> extracting"
    tar -xzf "${LAME_TARBALL}" -C "${WORK}"
fi

HOST_OS="$(uname | tr '[:upper:]' '[:lower:]')-x86_64"
TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/${HOST_OS}"
if [[ ! -d "${TOOLCHAIN}" ]]; then
    HOST_OS="$(uname | tr '[:upper:]' '[:lower:]')-arm64"
    TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/${HOST_OS}"
fi
[[ -d "${TOOLCHAIN}" ]] || { echo "ERROR: toolchain not at ${TOOLCHAIN}"; exit 3; }

build_abi() {
    local abi="$1" host="$2" cc_prefix="$3"
    local out_dir="${WORK}/build-${abi}"
    local install_dir="${WORK}/install-${abi}"
    mkdir -p "${out_dir}"
    (
        cd "${LAME_SRC}"
        make distclean >/dev/null 2>&1 || true
        export CC="${TOOLCHAIN}/bin/${cc_prefix}${API}-clang"
        export AR="${TOOLCHAIN}/bin/llvm-ar"
        export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
        export STRIP="${TOOLCHAIN}/bin/llvm-strip"
        export CFLAGS="-O2 -fPIC -DSTDC_HEADERS"
        ./configure \
            --host="${host}" \
            --prefix="${install_dir}" \
            --disable-static --enable-shared \
            --disable-frontend --disable-decoder --disable-analyzer-hooks \
            >"${out_dir}/configure.log" 2>&1
        make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" >"${out_dir}/build.log" 2>&1
        make install >"${out_dir}/install.log" 2>&1
    )
    local so="${install_dir}/lib/libmp3lame.so"
    [[ -f "${so}" ]] || { echo "ERROR: no .so at ${so}"; exit 4; }
    mkdir -p "${JNI_LIBS}/${abi}"
    cp "${so}" "${JNI_LIBS}/${abi}/libmp3lame.so"
    echo ">> ${abi} → ${JNI_LIBS}/${abi}/libmp3lame.so"
}

build_abi arm64-v8a     aarch64-linux-android  aarch64-linux-android
build_abi armeabi-v7a   armv7a-linux-androideabi armv7a-linux-androideabi
build_abi x86_64        x86_64-linux-android   x86_64-linux-android
build_abi x86           i686-linux-android     i686-linux-android

echo ">> LAME 3.100 built for all 4 ABIs. Run a Gradle build; LameStub.isAvailable() now true."
