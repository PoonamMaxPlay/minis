// C surface shared by the iOS Swift engine and the Android JNI bridge.
//
// The struct/typedef definitions live in
// android/src/main/cpp/videdit/ff_common.h, which this header re-exports
// via a relative include so iOS and Android compile against identical
// definitions (no risk of layout drift).
#ifndef LOOPIT_MINIS_FF_BRIDGE_H
#define LOOPIT_MINIS_FF_BRIDGE_H

#include "../../../../android/src/main/cpp/videdit/ff_common.h"
#include "../../../../android/src/main/cpp/videdit/ff_session.h"

#ifdef __cplusplus
extern "C" {
#endif

int ff_trim_run(const char* in_path, const char* out_path,
                int64_t in_ms, int64_t out_ms, int reencode,
                ff_progress_cb_t* cb);
int ff_concat_run(const char* const* in_paths, int n_paths,
                  const char* out_path, double speed, int keep_audio,
                  const char* music_path, int64_t music_in_ms, int64_t music_out_ms,
                  int keep_music_tempo,
                  ff_progress_cb_t* cb);
int ff_repair_run(const char* in_path, const char* out_path,
                  int target_height, ff_progress_cb_t* cb);
int ff_thumbstrip_run(const char* in_path, int count, int w, int h,
                      const char* out_dir, char*** out_paths, int* out_n);
int ff_export_run(const char* timeline_json, const char* preset,
                  const char* out_path, const char* options_json,
                  ff_progress_cb_t* cb);
int ff_export_cancel(const char* task_id);
int ff_subtitles_burn(const char* in_path, const char* out_path,
                      const char* srt_path, const char* style,
                      ff_progress_cb_t* cb);
int ff_bg_compose_run(const char* in_path, const char* mask_atlas_path,
                      const char* bg_spec, const char* out_path,
                      ff_progress_cb_t* cb);
int ff_audio_mix_run(const char* const* audio_paths, int n_paths,
                     const char* filter_str, const char* out_path,
                     ff_progress_cb_t* cb);
int ff_av_remux_run(const char* video_path, const char* audio_path,
                    const char* out_path, ff_progress_cb_t* cb);

#ifdef __cplusplus
}
#endif

#endif // LOOPIT_MINIS_FF_BRIDGE_H
