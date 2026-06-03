#!/usr/bin/env bash
#
# Cross-compiles FFmpeg (+ x264, x265, fdk-aac, opus, libvpx) for the three
# iOS slices we ship (arm64 device, arm64 simulator, x86_64 simulator) and
# assembles the result into ios/Frameworks/FFmpeg.xcframework.
#
# Requires Xcode 15+, autoconf, automake, libtool, pkg-config, yasm, nasm,
# cmake, ninja. The dependency sources must be cloned under ./external/
# beforehand; see the README in this directory.
#
# Run from ios/ffmpeg/:
#   ./build_ios.sh                    # builds all three slices
#   SLICES=ios-arm64 ./build_ios.sh   # builds a single slice
set -euo pipefail

JOBS="$(sysctl -n hw.ncpu)"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/external"
OUT="$ROOT/out"
FW_OUT="$ROOT/../Frameworks"
mkdir -p "$OUT" "$FW_OUT"

SLICES=(${SLICES:-ios-arm64 ios-arm64-simulator ios-x86_64-simulator})

DEVELOPER="$(xcode-select -p)"
MIN_IOS=12.0

for slice in "${SLICES[@]}"; do
  case "$slice" in
    ios-arm64)
      ARCH=arm64
      PLATFORM=iPhoneOS
      SDK=iphoneos
      CFLAGS_EXTRA="-arch arm64 -miphoneos-version-min=${MIN_IOS}"
      HOST=aarch64-apple-darwin
      VPX_TARGET=arm64-darwin-gcc
      ;;
    ios-arm64-simulator)
      ARCH=arm64
      PLATFORM=iPhoneSimulator
      SDK=iphonesimulator
      CFLAGS_EXTRA="-arch arm64 -mios-simulator-version-min=${MIN_IOS}"
      HOST=aarch64-apple-darwin
      VPX_TARGET=arm64-darwin-gcc
      ;;
    ios-x86_64-simulator)
      ARCH=x86_64
      PLATFORM=iPhoneSimulator
      SDK=iphonesimulator
      CFLAGS_EXTRA="-arch x86_64 -mios-simulator-version-min=${MIN_IOS}"
      HOST=x86_64-apple-darwin
      VPX_TARGET=x86_64-darwin-gcc
      ;;
    *) echo "unknown slice: $slice"; exit 1 ;;
  esac

  SYSROOT="$DEVELOPER/Platforms/${PLATFORM}.platform/Developer/SDKs/${PLATFORM}.sdk"
  if [[ ! -d "$SYSROOT" ]]; then
    echo "missing sysroot: $SYSROOT"; exit 1
  fi

  CC="$(xcrun --sdk "$SDK" --find clang)"
  CXX="$(xcrun --sdk "$SDK" --find clang++)"
  AR="$(xcrun --sdk "$SDK" --find ar)"
  RANLIB="$(xcrun --sdk "$SDK" --find ranlib)"
  STRIP="$(xcrun --sdk "$SDK" --find strip)"

  PREFIX="$OUT/$slice"
  mkdir -p "$PREFIX"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

  COMMON_CFLAGS="-isysroot $SYSROOT $CFLAGS_EXTRA -fPIC -O3 -I$PREFIX/include"
  COMMON_LDFLAGS="-isysroot $SYSROOT $CFLAGS_EXTRA -L$PREFIX/lib"

  # ── x264 ────────────────────────────────────────────────
  pushd "$SRC/x264" >/dev/null
  make clean >/dev/null 2>&1 || true
  CC="$CC" CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
    --enable-pic --enable-static --disable-cli \
    --disable-asm
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── x265 ────────────────────────────────────────────────
  X265_BUILD="$SRC/x265/build/$slice"
  mkdir -p "$X265_BUILD"
  pushd "$X265_BUILD" >/dev/null
  cmake -G Ninja "$SRC/x265/source" \
    -DCMAKE_OSX_SYSROOT="$SYSROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF
  ninja
  ninja install
  popd >/dev/null

  # ── fdk-aac ─────────────────────────────────────────────
  pushd "$SRC/fdk-aac" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./autogen.sh
  CC="$CC" CXX="$CXX" CFLAGS="$COMMON_CFLAGS" CXXFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
    --enable-static --disable-shared --with-pic
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── opus ────────────────────────────────────────────────
  pushd "$SRC/opus" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./autogen.sh
  CC="$CC" CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
    --enable-static --disable-shared --with-pic \
    --disable-doc --disable-extra-programs
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── libvpx ──────────────────────────────────────────────
  pushd "$SRC/libvpx" >/dev/null
  make clean >/dev/null 2>&1 || true
  CC="$CC" CXX="$CXX" CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
  ./configure --prefix="$PREFIX" --target="$VPX_TARGET" \
    --enable-pic --enable-vp9 --enable-vp8 \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── ffmpeg ──────────────────────────────────────────────
  pushd "$SRC/ffmpeg" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./configure \
    --prefix="$PREFIX" \
    --target-os=darwin --arch="$ARCH" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" \
    --sysroot="$SYSROOT" \
    --enable-cross-compile --enable-pic \
    --enable-static --disable-shared \
    --disable-programs --disable-doc --disable-debug \
    --enable-version3 --enable-pthreads --enable-hardcoded-tables \
    --disable-everything \
    --enable-avformat --enable-avcodec --enable-avfilter \
    --enable-swscale --enable-swresample --enable-postproc --enable-network \
    --enable-protocol=file,pipe,concat,data,async,subfile \
    --enable-libx264 --enable-libx265 --enable-libfdk-aac \
    --enable-libopus --enable-libvpx --enable-nonfree \
    --enable-videotoolbox \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
    --enable-parser=h264,hevc,vp9,aac,opus,mpeg4video \
    --enable-filter=scale,crop,trim,atrim,concat,overlay,subtitles,lut3d,fade,afade,amix,asetpts,setpts,reverse,areverse,curves,vidstabdetect,vidstabtransform,nlmeans,hflip,vflip,rotate,format,colorspace,volume,acrossfade,loudnorm,aresample,pan,sidechaincompress,unsharp,hqdn3d,palettegen,paletteuse \
    --enable-demuxer=mov,mp4,matroska,webm,concat,image2,gif,wav,aac,ogg,flac,mp3,mpegts \
    --enable-muxer=mp4,mov,matroska,webm,gif,image2,wav,null \
    --enable-encoder=h264_videotoolbox,hevc_videotoolbox,libx264,libx265,aac,libfdk_aac,libopus,libvpx_vp9,prores_ks,gif,png,mjpeg,pcm_s16le \
    --enable-decoder=h264,hevc,vp9,vp8,av1,aac,opus,mp3,vorbis,mjpeg,pcm_s16le,gif,png \
    --extra-cflags="$COMMON_CFLAGS -DPIC" \
    --extra-ldflags="$COMMON_LDFLAGS" \
    --extra-libs="-lm -lz -lbz2 -liconv -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework AudioToolbox -framework VideoToolbox -framework Security" \
    --pkg-config=pkg-config
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── Stage a fat static .a per library, ready for xcframework ──
  STAGE="$OUT/stage/$slice/FFmpeg.framework"
  mkdir -p "$STAGE/Headers"
  cp -R "$PREFIX/include/." "$STAGE/Headers/"
  # Build a single combined static archive named "FFmpeg" to expose as a
  # framework binary. libtool -static merges archives without duplicates.
  libtool -static -o "$STAGE/FFmpeg" \
    "$PREFIX/lib/libavcodec.a" \
    "$PREFIX/lib/libavformat.a" \
    "$PREFIX/lib/libavfilter.a" \
    "$PREFIX/lib/libavutil.a" \
    "$PREFIX/lib/libswscale.a" \
    "$PREFIX/lib/libswresample.a" \
    "$PREFIX/lib/libpostproc.a" \
    "$PREFIX/lib/libx264.a" \
    "$PREFIX/lib/libx265.a" \
    "$PREFIX/lib/libfdk-aac.a" \
    "$PREFIX/lib/libopus.a" \
    "$PREFIX/lib/libvpx.a"

  cat > "$STAGE/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FFmpeg</string>
  <key>CFBundleIdentifier</key><string>com.loopit.minis.FFmpeg</string>
  <key>CFBundleName</key><string>FFmpeg</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>6.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>${MIN_IOS}</string>
</dict></plist>
EOF
  echo "✅ $slice staged"
done

# ── Combine slices into FFmpeg.xcframework ───────────────
rm -rf "$FW_OUT/FFmpeg.xcframework"
ARGS=()
for slice in "${SLICES[@]}"; do
  ARGS+=(-framework "$OUT/stage/$slice/FFmpeg.framework")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$FW_OUT/FFmpeg.xcframework"

echo "✅ FFmpeg.xcframework written to $FW_OUT/FFmpeg.xcframework"
