/* JNI bridge to LAME (libmp3lame). Built only when `find_library(LAME mp3lame)`
 * resolves. See lame_README.md for vendoring instructions. */

#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include <lame/lame.h>

JNIEXPORT jlong JNICALL
Java_com_loopit_minis_audio_LameStub_nativeInit(
        JNIEnv *env, jobject thiz, jint sampleRate, jint channels, jint kbps) {
    (void) env; (void) thiz;
    lame_t lame = lame_init();
    if (!lame) return 0;
    lame_set_in_samplerate(lame, sampleRate);
    lame_set_num_channels(lame, channels);
    lame_set_brate(lame, kbps);
    lame_set_VBR(lame, vbr_off);
    lame_set_quality(lame, 2);
    if (lame_init_params(lame) < 0) {
        lame_close(lame);
        return 0;
    }
    return (jlong)(intptr_t) lame;
}

JNIEXPORT jint JNICALL
Java_com_loopit_minis_audio_LameStub_nativeEncode(
        JNIEnv *env, jobject thiz, jlong handle, jfloatArray pcm, jint frames, jbyteArray mp3Out) {
    (void) thiz;
    lame_t lame = (lame_t)(intptr_t) handle;
    if (!lame || frames <= 0) return 0;
    jfloat *pcmPtr = (*env)->GetFloatArrayElements(env, pcm, NULL);
    jbyte *mp3Ptr = (*env)->GetByteArrayElements(env, mp3Out, NULL);
    jsize mp3Cap = (*env)->GetArrayLength(env, mp3Out);
    int n = lame_encode_buffer_interleaved_ieee_float(
            lame, pcmPtr, frames, (unsigned char *) mp3Ptr, (int) mp3Cap);
    (*env)->ReleaseFloatArrayElements(env, pcm, pcmPtr, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, mp3Out, mp3Ptr, 0);
    return n < 0 ? 0 : n;
}

JNIEXPORT jint JNICALL
Java_com_loopit_minis_audio_LameStub_nativeFinish(
        JNIEnv *env, jobject thiz, jlong handle, jbyteArray mp3Out) {
    (void) thiz;
    lame_t lame = (lame_t)(intptr_t) handle;
    if (!lame) return 0;
    jbyte *mp3Ptr = (*env)->GetByteArrayElements(env, mp3Out, NULL);
    jsize mp3Cap = (*env)->GetArrayLength(env, mp3Out);
    int n = lame_encode_flush(lame, (unsigned char *) mp3Ptr, (int) mp3Cap);
    (*env)->ReleaseByteArrayElements(env, mp3Out, mp3Ptr, 0);
    return n < 0 ? 0 : n;
}

JNIEXPORT void JNICALL
Java_com_loopit_minis_audio_LameStub_nativeClose(
        JNIEnv *env, jobject thiz, jlong handle) {
    (void) env; (void) thiz;
    lame_t lame = (lame_t)(intptr_t) handle;
    if (lame) lame_close(lame);
}
