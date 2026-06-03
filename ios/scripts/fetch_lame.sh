#!/usr/bin/env bash
# Fetch + build LAME 3.100 for iOS (arm64 device + arm64/x86_64 simulator) and
# produce a fat static library at ios/Vendor/lame/libmp3lame.a + lame.h.
#
# Requirements: curl, tar, Xcode + command-line tools.
# Run once: ./ios/scripts/fetch_lame.sh
#
# After this finishes, MinisLameEncoder.isAvailable() flips true and the iOS
# Recorder MP3 path records end-to-end. Add to your podspec:
#     s.vendored_libraries = 'Vendor/lame/libmp3lame.a'
#     s.public_header_files = 'Vendor/lame/include/lame.h'
#     s.preserve_paths = 'Vendor/lame/**/*'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK="${ROOT}/ios/.lame-build"
OUT="${ROOT}/ios/Vendor/lame"
LAME_VERSION="3.100"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"
LAME_TARBALL="${WORK}/lame-${LAME_VERSION}.tar.gz"
LAME_SRC="${WORK}/lame-${LAME_VERSION}"

mkdir -p "${WORK}" "${OUT}/include"

if [[ ! -f "${LAME_TARBALL}" ]]; then
    echo ">> fetching LAME ${LAME_VERSION}"
    curl -fsSL "${LAME_URL}" -o "${LAME_TARBALL}"
fi

if [[ ! -d "${LAME_SRC}" ]]; then
    echo ">> extracting"
    tar -xzf "${LAME_TARBALL}" -C "${WORK}"
fi

build_slice() {
    local slice="$1" sdk="$2" host="$3" min="$4" arch="$5"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    local prefix="${WORK}/install-${slice}"
    mkdir -p "${prefix}"
    (
        cd "${LAME_SRC}"
        make distclean >/dev/null 2>&1 || true
        export CC="$(xcrun --sdk "${sdk}" -f clang)"
        export CFLAGS="-arch ${arch} -isysroot ${sdk_path} -m${min}-version-min=12.0 -fembed-bitcode -O2"
        ./configure \
            --host="${host}" \
            --prefix="${prefix}" \
            --enable-static --disable-shared \
            --disable-frontend --disable-decoder --disable-analyzer-hooks \
            >"${WORK}/configure-${slice}.log" 2>&1
        make -j"$(sysctl -n hw.ncpu)" >"${WORK}/build-${slice}.log" 2>&1
        make install >"${WORK}/install-${slice}.log" 2>&1
    )
    echo "${prefix}/lib/libmp3lame.a"
}

DEV_A="$(build_slice device       iphoneos          arm64-apple-darwin  iphoneos          arm64)"
SIM_A="$(build_slice sim-arm64    iphonesimulator   arm64-apple-darwin  iphonesimulator   arm64)"
SIM_X="$(build_slice sim-x86_64   iphonesimulator   x86_64-apple-darwin iphonesimulator   x86_64)"

# Fat sim lib first (arm64 + x86_64) then a single fat static (device + sim) via lipo.
SIM_FAT="${WORK}/libmp3lame-sim.a"
lipo -create "${SIM_A}" "${SIM_X}" -output "${SIM_FAT}"
lipo -create "${DEV_A}" "${SIM_FAT}" -output "${OUT}/libmp3lame.a"

cp "${LAME_SRC}/include/lame.h" "${OUT}/include/lame.h"

echo ">> wrote ${OUT}/libmp3lame.a + include/lame.h"
echo ">> add to podspec:"
echo "      s.vendored_libraries  = 'Vendor/lame/libmp3lame.a'"
echo "      s.public_header_files = 'Vendor/lame/include/lame.h'"
echo "      s.preserve_paths      = 'Vendor/lame/**/*'"
