// On iOS the C surface in ff_bridge.h is satisfied by the same C files we
// ship for Android (ff_session.c, ff_trim.c, ff_concat.c, ff_repair.c,
// ff_thumbstrip.c, ff_export.c, ff_audio_graph.c). To avoid duplication,
// the canonical sources live under android/src/main/cpp/videdit/ and this
// translation unit pulls them in by relative include — Xcode/CocoaPods
// compile exactly one .c (this one) for the iOS slice.
//
// The included files are POSIX-clean and depend only on FFmpeg headers
// surfaced through ios/Frameworks/FFmpeg.xcframework.

#include "ff_bridge.h"

#define FF_BRIDGE_IOS 1

#include "../../../../android/src/main/cpp/videdit/ff_session.c"
#include "../../../../android/src/main/cpp/videdit/ff_trim.c"
#include "../../../../android/src/main/cpp/videdit/ff_concat.c"
#include "../../../../android/src/main/cpp/videdit/ff_repair.c"
#include "../../../../android/src/main/cpp/videdit/ff_thumbstrip.c"
#include "../../../../android/src/main/cpp/videdit/ff_export.c"
#include "../../../../android/src/main/cpp/videdit/ff_progress.c"
#include "../../../../android/src/main/cpp/videdit/ff_audio_graph.c"
#include "../../../../android/src/main/cpp/videdit/ff_subtitles.c"
#include "../../../../android/src/main/cpp/videdit/ff_bg_compose.c"
#include "../../../../android/src/main/cpp/videdit/ff_audio_mix.c"
