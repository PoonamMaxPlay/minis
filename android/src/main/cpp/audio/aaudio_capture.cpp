// AAudio low-latency capture → Kotlin callback bridge. API 26+.
// Builds against NDK aaudio headers; soft-links libaaudio.so.

#include "aaudio_capture.h"

#include <android/log.h>
#include <aaudio/AAudio.h>

#include <atomic>
#include <cstdlib>
#include <cstring>

#define LOG_TAG "minis.aaudio"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

struct Session {
    AAudioStream *stream{nullptr};
    JavaVM *vm{nullptr};
    jobject sinkGlobal{nullptr};
    jmethodID onSamples{nullptr};
    int channels{1};
    std::atomic<bool> running{false};
};

aaudio_data_callback_result_t dataCallback(
        AAudioStream * /*stream*/, void *userData, void *audioData, int32_t numFrames) {
    auto *s = static_cast<Session *>(userData);
    if (!s || !s->running.load() || !s->vm || !s->sinkGlobal || !s->onSamples) {
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }
    JNIEnv *env = nullptr;
    bool attached = false;
    if (s->vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (s->vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            return AAUDIO_CALLBACK_RESULT_CONTINUE;
        }
        attached = true;
    }
    const int total = numFrames * s->channels;
    jfloatArray arr = env->NewFloatArray(total);
    if (arr != nullptr) {
        env->SetFloatArrayRegion(arr, 0, total, static_cast<const jfloat *>(audioData));
        env->CallVoidMethod(s->sinkGlobal, s->onSamples, arr);
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(arr);
    }
    if (attached) s->vm->DetachCurrentThread();
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

void errorCallback(AAudioStream * /*stream*/, void * /*userData*/, aaudio_result_t error) {
    LOGW("aaudio error: %d", error);
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_loopit_minis_audio_AaudioCapture_nativeStart(
        JNIEnv *env, jobject /*thiz*/, jint sampleRate, jint channels, jobject sink) {
    auto *s = new Session();
    env->GetJavaVM(&s->vm);
    s->channels = channels;
    s->sinkGlobal = env->NewGlobalRef(sink);
    jclass cls = env->GetObjectClass(sink);
    s->onSamples = env->GetMethodID(cls, "onSamples", "([F)V");
    env->DeleteLocalRef(cls);
    if (!s->onSamples) {
        LOGE("onSamples method not found");
        if (s->sinkGlobal) env->DeleteGlobalRef(s->sinkGlobal);
        delete s;
        return 0;
    }

    AAudioStreamBuilder *builder = nullptr;
    if (AAudio_createStreamBuilder(&builder) != AAUDIO_OK || !builder) {
        if (s->sinkGlobal) env->DeleteGlobalRef(s->sinkGlobal);
        delete s;
        return 0;
    }
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_INPUT);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
    AAudioStreamBuilder_setSampleRate(builder, sampleRate);
    AAudioStreamBuilder_setChannelCount(builder, channels);
    AAudioStreamBuilder_setDataCallback(builder, dataCallback, s);
    AAudioStreamBuilder_setErrorCallback(builder, errorCallback, s);

    aaudio_result_t r = AAudioStreamBuilder_openStream(builder, &s->stream);
    if (r != AAUDIO_OK || !s->stream) {
        // Retry with SHARED mode — EXCLUSIVE often refused on capture path.
        AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
        r = AAudioStreamBuilder_openStream(builder, &s->stream);
    }
    AAudioStreamBuilder_delete(builder);

    if (r != AAUDIO_OK || !s->stream) {
        LOGE("openStream failed: %d", r);
        env->DeleteGlobalRef(s->sinkGlobal);
        delete s;
        return 0;
    }

    s->running.store(true);
    r = AAudioStream_requestStart(s->stream);
    if (r != AAUDIO_OK) {
        LOGE("requestStart failed: %d", r);
        s->running.store(false);
        AAudioStream_close(s->stream);
        env->DeleteGlobalRef(s->sinkGlobal);
        delete s;
        return 0;
    }
    return reinterpret_cast<jlong>(s);
}

extern "C" JNIEXPORT void JNICALL
Java_com_loopit_minis_audio_AaudioCapture_nativeStop(
        JNIEnv *env, jobject /*thiz*/, jlong handle) {
    auto *s = reinterpret_cast<Session *>(handle);
    if (!s) return;
    s->running.store(false);
    if (s->stream) {
        AAudioStream_requestStop(s->stream);
        AAudioStream_close(s->stream);
        s->stream = nullptr;
    }
    if (s->sinkGlobal) {
        env->DeleteGlobalRef(s->sinkGlobal);
        s->sinkGlobal = nullptr;
    }
    delete s;
}
