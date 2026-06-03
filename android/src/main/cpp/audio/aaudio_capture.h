#pragma once

#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

// JNI exports: declared so the runtime linker can locate them.
JNIEXPORT jlong JNICALL
Java_com_loopit_minis_audio_AaudioCapture_nativeStart(
        JNIEnv *env, jobject thiz, jint sampleRate, jint channels, jobject sink);

JNIEXPORT void JNICALL
Java_com_loopit_minis_audio_AaudioCapture_nativeStop(
        JNIEnv *env, jobject thiz, jlong handle);

#ifdef __cplusplus
}
#endif
