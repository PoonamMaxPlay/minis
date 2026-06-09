cmake_minimum_required(VERSION 3.18.1)
project(minis_native)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_library(log-lib log)
find_library(android-lib android)
find_library(egl-lib EGL)
find_library(gles3-lib GLESv3)
find_library(jnigraphics-lib jnigraphics)

# --- camera pipeline --------------------------------------------------------
add_library(
    minis_camera_pipeline
    SHARED
    camera_pipeline.cpp
)
target_link_libraries(minis_camera_pipeline ${log-lib})

# Optional: link `libyuv` from a vendored AAR / system path when present.
find_library(yuv-lib yuv)
if (yuv-lib)
    target_link_libraries(minis_camera_pipeline ${yuv-lib})
    target_compile_definitions(minis_camera_pipeline PRIVATE MINIS_HAS_LIBYUV=1)
endif ()

# --- image edit pipeline ----------------------------------------------------
add_library(
    minis_imgedit
    SHARED
    imgedit/egl_context.cpp
    imgedit/render_graph.cpp
    imgedit/pipeline.cpp
    imgedit/lut.cpp
    imgedit/heal.cpp
    imgedit/liquify.cpp
    imgedit/crop.cpp
    imgedit/jni_bridge.cpp
)

target_include_directories(minis_imgedit PRIVATE imgedit)

target_link_libraries(
    minis_imgedit
    ${log-lib}
    ${android-lib}
    ${egl-lib}
    ${gles3-lib}
    ${jnigraphics-lib}
)

# --- aaudio low-latency capture --------------------------------------------
find_library(aaudio-lib aaudio)
if (aaudio-lib)
    add_library(
        minis_audio_aaudio
        SHARED
        audio/aaudio_capture.cpp
    )
    target_include_directories(minis_audio_aaudio PRIVATE audio)
    target_link_libraries(
        minis_audio_aaudio
        ${aaudio-lib}
        ${log-lib}
        ${android-lib}
    )
else ()
    message(WARNING "libaaudio not found; skipping minis_audio_aaudio build")
endif ()

# --- optional LAME MP3 bridge ----------------------------------------------
find_library(LAME_LIB mp3lame)
if (LAME_LIB)
    add_library(
        minis_audio_lame
        SHARED
        audio/lame_bridge.c
    )
    target_include_directories(minis_audio_lame PRIVATE audio)
    target_link_libraries(minis_audio_lame ${LAME_LIB} ${log-lib})
else ()
    message(STATUS "libmp3lame not found; MP3 export disabled. "
                   "See android/src/main/cpp/audio/lame_README.md to vendor it.")
endif ()

# --- video edit pipeline ----------------------------------------------------
#
# Replaced by the prebuilt FFmpegKit Android artifact
# (`com.arthenica:ffmpeg-kit-min-gpl`) declared in android/build.gradle. The
# AAR ships avformat/avcodec/avfilter/swscale/swresample/avutil .so files for
# every ABI and a Java/Kotlin API on top, so we no longer build
# `libminis_videdit.so` from source. The C glue under videdit/ is kept as
# reference only — none of the sources are compiled here.
