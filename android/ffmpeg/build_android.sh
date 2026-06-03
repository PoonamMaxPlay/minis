#!/usr/bin/env bash
#
# Cross-compiles FFmpeg (+ x264, x265, fdk-aac, opus, libvpx) for Android using
# the NDK and installs the resulting shared libraries into the plugin's
# jniLibs/<abi> directories.
#
# Requirements:
#   - ANDROID_NDK_HOME pointing at an installed NDK (r26b recommended).
#   - autoconf, automake, libtool, pkg-config, yasm, nasm, cmake, ninja, make.
#
# Run from the android/ffmpeg/ directory:
#   ./build_android.sh                  # builds all ABIs
#   ABIS=arm64-v8a ./build_android.sh   # builds a single ABI
#
# Sources for ffmpeg + deps must be cloned into ./external/ first; see
# docker/Dockerfile for the canonical clone commands.
set -euo pipefail

NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"

case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64 ;;
  Linux)  HOST_TAG=linux-x86_64 ;;
  *)      echo "unsupported host: $(uname -s)"; exit 1 ;;
esac

if [[ "$(uname -s)" == "Darwin" ]]; then
  JOBS="$(sysctl -n hw.ncpu)"
else
  JOBS="$(nproc)"
fi

ABIS=(${ABIS:-arm64-v8a armeabi-v7a x86_64 x86})
API="${API:-26}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/external"
OUT="$ROOT/out"
JNI_OUT="$ROOT/../src/main/jniLibs"
mkdir -p "$OUT" "$JNI_OUT"

for required in ffmpeg x264 x265 fdk-aac opus libvpx; do
  if [[ ! -d "$SRC/$required" ]]; then
    echo "missing source: $SRC/$required (see docker/Dockerfile)" >&2
    exit 1
  fi
done

for ABI in "${ABIS[@]}"; do
  case "$ABI" in
    arm64-v8a)
      TARGET=aarch64-linux-android
      CLANG_TARGET=aarch64-linux-android
      ARCH=arm64
      CPU=armv8-a
      ;;
    armeabi-v7a)
      TARGET=armv7a-linux-androideabi
      CLANG_TARGET=armv7a-linux-androideabi
      ARCH=arm
      CPU=armv7-a
      ;;
    x86_64)
      TARGET=x86_64-linux-android
      CLANG_TARGET=x86_64-linux-android
      ARCH=x86_64
      CPU=x86_64
      ;;
    x86)
      TARGET=i686-linux-android
      CLANG_TARGET=i686-linux-android
      ARCH=x86
      CPU=i686
      ;;
    *) echo "unknown ABI: $ABI"; exit 1 ;;
  esac

  TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  CC="$TOOLCHAIN/bin/${CLANG_TARGET}${API}-clang"
  CXX="$TOOLCHAIN/bin/${CLANG_TARGET}${API}-clang++"
  AR="$TOOLCHAIN/bin/llvm-ar"
  RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  STRIP="$TOOLCHAIN/bin/llvm-strip"
  NM="$TOOLCHAIN/bin/llvm-nm"

  PREFIX="$OUT/$ABI"
  mkdir -p "$PREFIX"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

  # ── x264 ────────────────────────────────────────────────
  pushd "$SRC/x264" >/dev/null
  make clean >/dev/null 2>&1 || true
  CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
  ./configure --prefix="$PREFIX" --host="$TARGET" \
    --enable-pic --enable-static --disable-cli \
    --disable-asm
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── x265 ────────────────────────────────────────────────
  X265_BUILD="$SRC/x265/build/$ABI"
  mkdir -p "$X265_BUILD"
  pushd "$X265_BUILD" >/dev/null
  cmake -G Ninja "$SRC/x265/source" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF
  ninja
  ninja install
  popd >/dev/null

  # ── fdk-aac ─────────────────────────────────────────────
  pushd "$SRC/fdk-aac" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./autogen.sh
  CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
  ./configure --prefix="$PREFIX" --host="$TARGET" \
    --enable-static --disable-shared --with-pic
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── opus ────────────────────────────────────────────────
  pushd "$SRC/opus" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./autogen.sh
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
  ./configure --prefix="$PREFIX" --host="$TARGET" \
    --enable-static --disable-shared --with-pic \
    --disable-doc --disable-extra-programs
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── libvpx ──────────────────────────────────────────────
  pushd "$SRC/libvpx" >/dev/null
  make clean >/dev/null 2>&1 || true
  case "$ABI" in
    arm64-v8a)   VPX_TARGET=arm64-android-gcc ;;
    armeabi-v7a) VPX_TARGET=armv7-android-gcc ;;
    x86_64)      VPX_TARGET=x86_64-android-gcc ;;
    x86)         VPX_TARGET=x86-android-gcc ;;
  esac
  CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
  CROSS="${TOOLCHAIN}/bin/llvm-" \
  ./configure --prefix="$PREFIX" --target="$VPX_TARGET" \
    --enable-pic --enable-vp9 --enable-vp8 \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --sdk-path="$NDK"
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── ffmpeg ──────────────────────────────────────────────
  pushd "$SRC/ffmpeg" >/dev/null
  make clean >/dev/null 2>&1 || true
  ./configure \
    --prefix="$PREFIX" \
    --target-os=android --arch="$ARCH" --cpu="$CPU" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" --nm="$NM" \
    --sysroot="$TOOLCHAIN/sysroot" \
    --enable-cross-compile --enable-pic \
    --enable-shared --disable-static \
    --disable-programs --disable-doc --disable-debug \
    --enable-version3 --enable-pthreads --enable-hardcoded-tables \
    --disable-everything \
    --enable-avformat --enable-avcodec --enable-avfilter --enable-avdevice \
    --enable-swscale --enable-swresample --enable-postproc --enable-network \
    --enable-protocol=file,pipe,concat,data,async,subfile \
    --enable-libx264 --enable-libx265 --enable-libfdk-aac \
    --enable-libopus --enable-libvpx --enable-nonfree \
    --enable-mediacodec --enable-jni \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
    --enable-parser=h264,hevc,vp9,aac,opus,mpeg4video \
    --enable-filter=scale,crop,trim,atrim,concat,overlay,subtitles,lut3d,fade,afade,amix,asetpts,setpts,reverse,areverse,curves,vidstabdetect,vidstabtransform,nlmeans,hflip,vflip,rotate,format,colorspace,volume,acrossfade,loudnorm,aresample,pan,sidechaincompress,unsharp,hqdn3d,palettegen,paletteuse \
    --enable-demuxer=mov,mp4,matroska,webm,concat,image2,gif,wav,aac,ogg,flac,mp3,mpegts \
    --enable-muxer=mp4,mov,matroska,webm,gif,image2,wav,null \
    --enable-encoder=h264_mediacodec,hevc_mediacodec,libx264,libx265,aac,libfdk_aac,libopus,libvpx_vp9,prores_ks,gif,png,mjpeg,pcm_s16le \
    --enable-decoder=h264,hevc,vp9,vp8,av1,aac,opus,mp3,vorbis,mjpeg,pcm_s16le,gif,png \
    --extra-cflags="-O3 -fPIC -DANDROID -I$PREFIX/include" \
    --extra-ldflags="-L$PREFIX/lib" \
    --extra-libs="-lm -lz" \
    --pkg-config=pkg-config
  make -j"$JOBS"
  make install
  popd >/dev/null

  # ── Stage shared libs into the plugin jniLibs ─────────────
  ABI_OUT="$JNI_OUT/$ABI"
  mkdir -p "$ABI_OUT"
  # Each FFmpeg shared library carries a SONAME like libavcodec.so.60 or
  # libavcodec.so. We ship the bare libfoo.so (resolved symlink) so the
  # APK only contains one file per library.
  for so in libavcodec libavformat libavfilter libavutil libswscale libswresample libavdevice libpostproc; do
    src="$PREFIX/lib/${so}.so"
    if [[ -f "$src" ]]; then
      cp -L "$src" "$ABI_OUT/${so}.so"
      "$STRIP" "$ABI_OUT/${so}.so" || true
    else
      echo "warn: $src missing"
    fi
  done

  echo "✅ $ABI complete → $ABI_OUT"
done

echo "✅ all ABIs built; jniLibs populated at $JNI_OUT"
