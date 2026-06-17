// Audio filter graph builder (improvement3.md §C8).
//
// Given a small set of inputs (clip audio, music, voiceover) and a master
// envelope, this builds the filter description string consumed by
// `avfilter_graph_parse_ptr`:
//
//   [0:a]volume=...[a0]; [1:a]volume=...,afade=t=in:st=0:d=0.5[a1];
//   [a0][a1]amix=inputs=2:duration=longest[mixed];
//   [2:a]volume=1.0[voice];
//   [mixed][voice]sidechaincompress=threshold=0.05:ratio=8[ducked];
//   [ducked]loudnorm=I=-14:TP=-1.5:LRA=11[out]
//
// The actual filter execution is deferred to the export pipeline in
// `ff_export.c` (Phase 2.5 wires this string in via avfilter_graph_parse2).

#include "ff_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct ff_audio_track {
  int   input_index;
  float volume;
  int   fade_in_ms;
  int   fade_out_ms;
  int   is_voiceover;
  int   ducks_master;
} ff_audio_track_t;

size_t ff_audio_build_graph(const ff_audio_track_t* tracks, int n_tracks,
                            int lufs_normalize, char* out, size_t out_sz) {
  if (!tracks || n_tracks <= 0 || !out) return 0;
  size_t used = 0;
  used += (size_t)snprintf(out + used, out_sz - used, "");

  int has_voice = 0;
  for (int i = 0; i < n_tracks; i++) {
    if (tracks[i].is_voiceover) has_voice = 1;
  }

  // Per-track volume + fade.
  for (int i = 0; i < n_tracks; i++) {
    const ff_audio_track_t* t = &tracks[i];
    if (used >= out_sz) break;
    used += (size_t)snprintf(out + used, out_sz - used,
        "[%d:a]volume=%.3f", t->input_index, t->volume);
    if (t->fade_in_ms > 0) {
      used += (size_t)snprintf(out + used, out_sz - used,
          ",afade=t=in:st=0:d=%.3f", t->fade_in_ms / 1000.0);
    }
    if (t->fade_out_ms > 0) {
      used += (size_t)snprintf(out + used, out_sz - used,
          ",afade=t=out:st=0:d=%.3f", t->fade_out_ms / 1000.0);
    }
    used += (size_t)snprintf(out + used, out_sz - used, "[a%d];", i);
  }

  // amix non-voiceover tracks → [mixed].
  used += (size_t)snprintf(out + used, out_sz - used, "");
  int amix_count = 0;
  for (int i = 0; i < n_tracks; i++) {
    if (!tracks[i].is_voiceover) {
      used += (size_t)snprintf(out + used, out_sz - used, "[a%d]", i);
      amix_count++;
    }
  }
  if (amix_count > 0) {
    used += (size_t)snprintf(out + used, out_sz - used,
        "amix=inputs=%d:duration=longest[mixed];", amix_count);
  }

  // Voiceover ducking (sidechain compress, master <- music duck on speech).
  if (has_voice) {
    for (int i = 0; i < n_tracks; i++) {
      if (tracks[i].is_voiceover) {
        used += (size_t)snprintf(out + used, out_sz - used,
            "[a%d]volume=%.3f[voice%d];", i, tracks[i].volume, i);
      }
    }
    // Take first voice for simplicity (multi-voice case unwound when added).
    int v_idx = -1;
    for (int i = 0; i < n_tracks; i++) if (tracks[i].is_voiceover) { v_idx = i; break; }
    if (amix_count > 0 && v_idx >= 0) {
      used += (size_t)snprintf(out + used, out_sz - used,
          "[mixed][voice%d]sidechaincompress=threshold=0.05:ratio=8[ducked];", v_idx);
    }
  }

  const char* final_label = has_voice && amix_count > 0 ? "ducked" : (amix_count > 0 ? "mixed" : "a0");
  if (lufs_normalize) {
    used += (size_t)snprintf(out + used, out_sz - used,
        "[%s]loudnorm=I=-14:TP=-1.5:LRA=11[out]", final_label);
  } else {
    used += (size_t)snprintf(out + used, out_sz - used, "[%s]anull[out]", final_label);
  }
  return used;
}
