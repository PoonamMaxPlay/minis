# Reproducible Android FFmpeg cross-build container.
#
# Builds the dependency chain x264 → x265 → fdk-aac → opus → libvpx → ffmpeg
# for the four Android ABIs (arm64-v8a, armeabi-v7a, x86_64, x86) and stages
# the resulting .so files into android/src/main/jniLibs/<abi>/.
#
# Usage from repo root:
#   docker build -t loopit/minis-ffmpeg android/ffmpeg/docker
#   docker run --rm -v "$PWD":/workspace -w /workspace/android/ffmpeg \
#       loopit/minis-ffmpeg ./build_android.sh
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_NDK_HOME=/opt/android-ndk \
    LC_ALL=C.UTF-8 LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip git build-essential \
      autoconf automake libtool m4 pkg-config \
      yasm nasm cmake ninja-build python3 file \
    && rm -rf /var/lib/apt/lists/*

# NDK r26b
ARG NDK_VERSION=r26b
RUN curl -fsSL -o /tmp/ndk.zip \
      "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
    && unzip -q /tmp/ndk.zip -d /opt \
    && mv "/opt/android-ndk-${NDK_VERSION}" "${ANDROID_NDK_HOME}" \
    && rm /tmp/ndk.zip

# Source clones. Versions pinned to known-good tags.
ARG FFMPEG_TAG=n6.1
ARG X264_TAG=master
ARG X265_TAG=3.5
ARG FDK_AAC_TAG=v2.0.2
ARG OPUS_TAG=v1.4
ARG LIBVPX_TAG=v1.13.1

RUN mkdir -p /workspace/android/ffmpeg/external && cd /workspace/android/ffmpeg/external && \
    git clone --depth 1 --branch ${FFMPEG_TAG}   https://github.com/FFmpeg/FFmpeg.git ffmpeg && \
    git clone --depth 1 --branch ${X264_TAG}     https://code.videolan.org/videolan/x264.git x264 && \
    git clone --depth 1 --branch ${X265_TAG}     https://bitbucket.org/multicoreware/x265_git.git x265 && \
    git clone --depth 1 --branch ${FDK_AAC_TAG}  https://github.com/mstorsjo/fdk-aac.git fdk-aac && \
    git clone --depth 1 --branch ${OPUS_TAG}     https://github.com/xiph/opus.git opus && \
    git clone --depth 1 --branch ${LIBVPX_TAG}   https://chromium.googlesource.com/webm/libvpx libvpx

WORKDIR /workspace
