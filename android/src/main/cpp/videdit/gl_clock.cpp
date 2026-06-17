// Monotonic playback clock for the GL compositor.
//
// Provides:
//   - `now_us()`         — wall-clock-like time in microseconds.
//   - `play(start_us)`   — start playing from the given timeline position.
//   - `pause()`          — freeze position.
//   - `seek(us)`         — jump position without changing run state.
//   - `position_us()`    — current timeline position, accounting for the
//                          time elapsed since `play()` was called.
//
// All methods are thread-safe; the compositor reads `position_us()` once per
// frame and the host thread can mutate the state from a Kotlin/Swift
// MethodChannel handler without locking the render thread.

#include <atomic>
#include <chrono>
#include <mutex>

namespace minis_videdit {

class Clock {
 public:
  void play(int64_t from_us) {
    std::lock_guard<std::mutex> lock(m_);
    base_position_us_ = from_us;
    wall_start_us_ = wall_us();
    playing_ = true;
  }

  void pause() {
    std::lock_guard<std::mutex> lock(m_);
    if (playing_) {
      base_position_us_ = position_locked();
      playing_ = false;
    }
  }

  void seek(int64_t us) {
    std::lock_guard<std::mutex> lock(m_);
    base_position_us_ = us;
    if (playing_) wall_start_us_ = wall_us();
  }

  int64_t position_us() {
    std::lock_guard<std::mutex> lock(m_);
    return position_locked();
  }

  bool playing() {
    std::lock_guard<std::mutex> lock(m_);
    return playing_;
  }

 private:
  int64_t wall_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  }

  int64_t position_locked() {
    if (!playing_) return base_position_us_;
    return base_position_us_ + (wall_us() - wall_start_us_);
  }

  std::mutex m_;
  bool playing_ = false;
  int64_t base_position_us_ = 0;
  int64_t wall_start_us_ = 0;
};

}  // namespace minis_videdit

extern "C" {

void* gl_clock_create() { return new minis_videdit::Clock(); }
void  gl_clock_destroy(void* h) { delete static_cast<minis_videdit::Clock*>(h); }
void  gl_clock_play(void* h, int64_t from_us)  { static_cast<minis_videdit::Clock*>(h)->play(from_us); }
void  gl_clock_pause(void* h)                  { static_cast<minis_videdit::Clock*>(h)->pause(); }
void  gl_clock_seek(void* h, int64_t us)       { static_cast<minis_videdit::Clock*>(h)->seek(us); }
int64_t gl_clock_position_us(void* h)          { return static_cast<minis_videdit::Clock*>(h)->position_us(); }
int   gl_clock_playing(void* h)                { return static_cast<minis_videdit::Clock*>(h)->playing() ? 1 : 0; }

}  // extern "C"
