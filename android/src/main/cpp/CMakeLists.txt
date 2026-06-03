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

# --- video edit pipeline (improvement3.md) ---------------------------------
#
# Links against FFmpeg shared libraries (libavformat, libavcodec, etc.)
# staged into ../jniLibs/<abi>/ by android/ffmpeg/build_android.sh. When
# the .so files are absent (clean checkout), the library still builds but
# the JNI calls return ENGINE_MISSING at runtime via the nativeLoaded
# guard in VideoEditEngine.kt.

set(FFMPEG_LIBS_DIR ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
set(FFMPEG_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/../../../ffmpeg/out/${ANDROID_ABI}/include)

set(VIDEDIT_SOURCES
    videdit/ff_session.c
    videdit/ff_jni.c
    videdit/ff_trim.c
    videdit/ff_concat.c
    videdit/ff_repair.c
    videdit/ff_thumbstrip.c
    videdit/ff_export.c
    videdit/ff_progress.c
    videdit/ff_audio_graph.c
    videdit/ff_audio_mix.c
    videdit/ff_subtitles.c
    videdit/ff_bg_compose.c
    videdit/gl_compositor.cpp
    videdit/gl_clock.cpp
    videdit/gl_preview_jni.c
    videdit/mask_atlas.cpp
)

if (EXISTS ${FFMPEG_LIBS_DIR}/libavformat.so AND EXISTS ${FFMPEG_INCLUDE_DIR}/libavformat/avformat.h)
    add_library(minis_videdit SHARED ${VIDEDIT_SOURCES})
    target_include_directories(minis_videdit PRIVATE ${FFMPEG_INCLUDE_DIR})

    foreach (lib avformat avcodec avfilter avutil swscale swresample)
        add_library(ff_${lib} SHARED IMPORTED)
        set_target_properties(ff_${lib} PROPERTIES IMPORTED_LOCATION
            ${FFMPEG_LIBS_DIR}/lib${lib}.so)
        target_link_libraries(minis_videdit ff_${lib})
    endforeach ()

    find_library(mediandk-lib mediandk)
    target_link_libraries(minis_videdit
        ${log-lib}
        ${android-lib}
        ${egl-lib}
        ${gles3-lib}
        ${mediandk-lib})
else ()
    message(WARNING "FFmpeg jniLibs not found at ${FFMPEG_LIBS_DIR}; "
                    "skipping minis_videdit native build. Run "
                    "android/ffmpeg/build_android.sh to produce them.")
endif ()
