# LAME MP3 export — Android vendoring

LAME is GPL-licensed; ship it only when MP3 export is mandatory. When the
vendored library is absent, `LameStub.isAvailable()` returns `false` and
`Recorder.start(format: "mp3")` throws a named `IllegalStateException`.

## Quick path

```
ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<rev> ./android/scripts/fetch_lame.sh
```

That downloads LAME 3.100, builds it for all 4 ABIs against the NDK toolchain,
and copies `libmp3lame.so` into `android/src/main/jniLibs/<abi>/`. Run a Gradle
build afterwards — `LameStub.isAvailable()` flips true.

## Manual path

## 1. Download

```
curl -LO https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
tar xf lame-3.100.tar.gz
cd lame-3.100
```

## 2. Build per ABI

`API` should match the project's `minSdkVersion` (≥ 21). Set `NDK` to the
absolute NDK root (`$ANDROID_HOME/ndk/<rev>`).

```
NDK=$HOME/Library/Android/sdk/ndk/26.1.10909125
TOOL=$NDK/toolchains/llvm/prebuilt/darwin-x86_64
API=23
PREFIX_BASE=$PWD/out

build_one() {
    ABI=$1; TRIPLE=$2; CC_HOST=$3
    PREFIX=$PREFIX_BASE/$ABI
    make distclean 2>/dev/null
    PATH=$TOOL/bin:$PATH \
    CC=$TOOL/bin/${TRIPLE}${API}-clang \
    AR=$TOOL/bin/llvm-ar \
    RANLIB=$TOOL/bin/llvm-ranlib \
    ./configure --host=$CC_HOST --prefix=$PREFIX \
                --disable-frontend --disable-shared --enable-static \
                --disable-decoder --disable-analyzer-hooks
    make -j8
    make install
}

build_one arm64-v8a    aarch64-linux-android       aarch64-linux-android
build_one armeabi-v7a  armv7a-linux-androideabi    armv7a-linux-androideabi
build_one x86_64       x86_64-linux-android        x86_64-linux-android
build_one x86          i686-linux-android          i686-linux-android
```

The static `libmp3lame.a` ends up in `out/<abi>/lib/`. To produce a
shared object the bridge can link against:

```
for ABI in arm64-v8a armeabi-v7a x86_64 x86; do
  case $ABI in
    arm64-v8a)   TRIPLE=aarch64-linux-android ;;
    armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
    x86_64)      TRIPLE=x86_64-linux-android ;;
    x86)         TRIPLE=i686-linux-android ;;
  esac
  $TOOL/bin/${TRIPLE}${API}-clang -shared -o out/$ABI/libmp3lame.so \
    -Wl,--whole-archive out/$ABI/lib/libmp3lame.a -Wl,--no-whole-archive \
    -Wl,-soname,libmp3lame.so
done
```

## 3. Drop the .so files

```
android/src/main/jniLibs/arm64-v8a/libmp3lame.so
android/src/main/jniLibs/armeabi-v7a/libmp3lame.so
android/src/main/jniLibs/x86_64/libmp3lame.so
android/src/main/jniLibs/x86/libmp3lame.so
```

Also copy the LAME headers (`out/arm64-v8a/include/lame/`) somewhere CMake
can find them and point the project there (e.g. via
`target_include_directories(minis_audio_lame PRIVATE <path>/include)`).

## 4. JNI bridge wiring

The Kotlin facade is `com.loopit.minis.audio.LameStub`. The native exports
expected by `System.loadLibrary("minis_audio_lame")`:

```
Java_com_loopit_minis_audio_LameStub_nativeInit
Java_com_loopit_minis_audio_LameStub_nativeEncode
Java_com_loopit_minis_audio_LameStub_nativeFinish
Java_com_loopit_minis_audio_LameStub_nativeClose
```

These are implemented in `lame_bridge.c` and call:

* `lame_init` / `lame_init_params` (in nativeInit)
* `lame_encode_buffer_interleaved_ieee_float` (in nativeEncode)
* `lame_encode_flush` (in nativeFinish)
* `lame_close` (in nativeClose)

`CMakeLists.txt` only adds the `minis_audio_lame` target when `find_library`
locates `libmp3lame`; missing it is non-fatal.
