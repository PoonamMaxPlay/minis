// Small helper that wraps the cancel-token table consulted by the export /
// transcode / repair loops. Each task gets a UUID from the Kotlin/Swift
// host; the host calls `ff_export_cancel(taskId)` to flip the in-memory
// flag, and the loops poll it via the `ff_progress_cb_t.cancel_flag` field
// they were handed.
//
// The table is intentionally tiny (max 16 active tasks) — heavy workloads
// only have one running export at a time on mobile; the 16-slot cap
// catches programmer error rather than scale concerns.

#include "ff_common.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define FF_PROGRESS_MAX 16

typedef struct slot {
  char  task_id[64];
  int   in_use;
  int   cancelled;
} slot_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static slot_t g_slots[FF_PROGRESS_MAX];

static slot_t* find_slot_locked(const char* id) {
  for (int i = 0; i < FF_PROGRESS_MAX; i++) {
    if (g_slots[i].in_use && strncmp(g_slots[i].task_id, id, sizeof(g_slots[i].task_id)) == 0) {
      return &g_slots[i];
    }
  }
  return NULL;
}

int ff_progress_register(const char* task_id) {
  if (!task_id || !task_id[0]) return -1;
  pthread_mutex_lock(&g_lock);
  for (int i = 0; i < FF_PROGRESS_MAX; i++) {
    if (!g_slots[i].in_use) {
      strncpy(g_slots[i].task_id, task_id, sizeof(g_slots[i].task_id) - 1);
      g_slots[i].in_use = 1;
      g_slots[i].cancelled = 0;
      pthread_mutex_unlock(&g_lock);
      return 0;
    }
  }
  pthread_mutex_unlock(&g_lock);
  return -1;
}

void ff_progress_deregister(const char* task_id) {
  if (!task_id) return;
  pthread_mutex_lock(&g_lock);
  slot_t* s = find_slot_locked(task_id);
  if (s) memset(s, 0, sizeof(*s));
  pthread_mutex_unlock(&g_lock);
}

int ff_progress_is_cancelled(const char* task_id) {
  if (!task_id) return 0;
  pthread_mutex_lock(&g_lock);
  slot_t* s = find_slot_locked(task_id);
  int v = s ? s->cancelled : 0;
  pthread_mutex_unlock(&g_lock);
  return v;
}

int ff_export_cancel(const char* task_id) {
  if (!task_id) return -1;
  pthread_mutex_lock(&g_lock);
  slot_t* s = find_slot_locked(task_id);
  if (s) s->cancelled = 1;
  pthread_mutex_unlock(&g_lock);
  return s ? 0 : -1;
}
