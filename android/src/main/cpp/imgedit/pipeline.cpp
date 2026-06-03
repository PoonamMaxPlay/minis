#include "pipeline.h"
#include "egl_context.h"
#include "render_graph.h"
#include "lut.h"
#include "heal.h"
#include "liquify.h"
#include "crop.h"

#include <android/log.h>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <cstring>

#define LOG_TAG "MinisImgEdit"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace minis::imgedit {

namespace {

struct ExtraLayer {
  PassKind kind;
  GLuint tex{0};
  float opacity{1.0f};
  int blend{0};
};

class SessionImpl : public Session {
 public:
  SessionImpl(int32_t view_id, std::string source_path,
              int32_t source_w, int32_t source_h)
      : view_id_(view_id),
        source_path_(std::move(source_path)),
        source_w_(source_w),
        source_h_(source_h) {}

  ~SessionImpl() override { surface_destroyed(); }

  void surface_created(void* native_window) override {
    std::lock_guard<std::mutex> lk(mu_);
    egl_ = std::make_unique<EglContext>();
    if (!egl_->init(reinterpret_cast<ANativeWindow*>(native_window))) {
      LOGE("egl init failed");
      egl_.reset();
      return;
    }
    graph_ = std::make_unique<RenderGraph>();
    if (!graph_->init_programs()) {
      LOGE("graph init failed");
      graph_.reset();
      return;
    }
    int32_t w = egl_->width();
    int32_t h = egl_->height();
    graph_->resize(w, h);
    upload_base_();
    dirty_ = true;
    do_render_locked_();
  }

  void surface_changed(int32_t w, int32_t h) override {
    std::lock_guard<std::mutex> lk(mu_);
    if (!egl_ || !graph_) return;
    egl_->resize(w, h);
    graph_->resize(w, h);
    dirty_ = true;
    do_render_locked_();
  }

  void surface_destroyed() override {
    std::lock_guard<std::mutex> lk(mu_);
    if (egl_) egl_->make_current();
    if (base_tex_) { glDeleteTextures(1, &base_tex_); base_tex_ = 0; }
    for (auto& l : extras_) if (l.tex) glDeleteTextures(1, &l.tex);
    extras_.clear();
    if (lut_tex_) { glDeleteTextures(1, &lut_tex_); lut_tex_ = 0; }
    if (graph_) { graph_->destroy(); graph_.reset(); }
    if (egl_)   { egl_->destroy();   egl_.reset(); }
  }

  void request_render() override {
    std::lock_guard<std::mutex> lk(mu_);
    do_render_locked_();
  }

  void apply_adjust(const AdjustParams& p) override {
    std::lock_guard<std::mutex> lk(mu_);
    AdjustUniforms u = adjust_;
    if      (p.key == "exposure")   u.exposure = (float)p.value;
    else if (p.key == "contrast")   u.contrast = (float)p.value;
    else if (p.key == "saturation") u.saturation = (float)p.value;
    else if (p.key == "temperature")u.temperature = (float)p.value;
    else if (p.key == "tint")       u.tint = (float)p.value;
    else if (p.key == "sharpen")    u.sharpen = (float)p.value;
    else if (p.key == "clarity")    u.clarity = (float)p.value;
    else if (p.key == "dehaze")     u.dehaze = (float)p.value;
    adjust_ = u;
    dirty_ = true;
    if (graph_) graph_->set_adjust(adjust_);
  }

  void apply_filter(const LutParams& p) override {
    std::lock_guard<std::mutex> lk(mu_);
    lut_path_ = p.path;
    lut_intensity_ = (float)p.intensity;
    if (egl_) egl_->make_current();
    if (lut_tex_) { glDeleteTextures(1, &lut_tex_); lut_tex_ = 0; }
    int lut_size = 0;
    if (!p.path.empty()) {
      lut::ParsedLut parsed;
      if (lut::parse_cube(p.path, &parsed)) {
        lut_tex_ = lut::upload_to_gl_texture3d(parsed);
        lut_size = parsed.size;
      }
    }
    LutUniforms lu;
    lu.texture = lut_tex_;
    lu.size = lut_size;
    lu.intensity = lut_intensity_;
    if (graph_) graph_->set_lut(lu);
    dirty_ = true;
  }

  void apply_crop(const CropParams& p) override {
    std::lock_guard<std::mutex> lk(mu_);
    CropUniforms cu;
    crop::Mat3 m;
    if (p.perspective.size() == 8) {
      crop::PerspectiveCorners c;
      c.tl_x = (float)p.perspective[0]; c.tl_y = (float)p.perspective[1];
      c.tr_x = (float)p.perspective[2]; c.tr_y = (float)p.perspective[3];
      c.br_x = (float)p.perspective[4]; c.br_y = (float)p.perspective[5];
      c.bl_x = (float)p.perspective[6]; c.bl_y = (float)p.perspective[7];
      m = crop::solve_homography(c);
    } else {
      m = crop::crop_matrix(p.rect.x, p.rect.y, p.rect.w, p.rect.h,
                            (float)p.rotation_deg);
    }
    std::memcpy(cu.homography, m.data(), 9 * sizeof(float));
    cu.active = true;
    crop_ = cu;
    if (graph_) graph_->set_crop(crop_);
    dirty_ = true;
  }

  std::vector<uint8_t> read_pixels(int32_t* out_w, int32_t* out_h) override {
    std::lock_guard<std::mutex> lk(mu_);
    if (!egl_ || !graph_) {
      if (out_w) *out_w = 0;
      if (out_h) *out_h = 0;
      return {};
    }
    egl_->make_current();
    if (dirty_) do_render_locked_no_lock_();
    int32_t w = graph_->width();
    int32_t h = graph_->height();
    std::vector<uint8_t> buf(w * h * 4);
    GLuint read_fbo = 0;
    glGenFramebuffers(1, &read_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, read_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, graph_->output_texture(), 0);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &read_fbo);
    if (out_w) *out_w = w;
    if (out_h) *out_h = h;
    return buf;
  }

  // -- internal helpers ----------------------------------------------------

  void push_extra(PassKind kind, GLuint tex, float opacity, int blend) {
    std::lock_guard<std::mutex> lk(mu_);
    extras_.push_back({kind, tex, opacity, blend});
    dirty_ = true;
  }

  void set_base_pixels(const uint8_t* rgba, int32_t w, int32_t h) {
    std::lock_guard<std::mutex> lk(mu_);
    if (egl_) egl_->make_current();
    if (base_tex_ == 0) glGenTextures(1, &base_tex_);
    glBindTexture(GL_TEXTURE_2D, base_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    source_w_ = w;
    source_h_ = h;
    if (graph_) graph_->set_base_texture(base_tex_);
    dirty_ = true;
  }

  int32_t view_id() const { return view_id_; }

 private:
  void upload_base_() {
    // Base pixels uploaded via JNI bridge (Bitmap → bytes). Until that
    // happens we fall back to a 1×1 neutral texture so the graph runs.
    if (base_tex_ == 0) glGenTextures(1, &base_tex_);
    const uint8_t neutral[4] = {200, 200, 200, 255};
    glBindTexture(GL_TEXTURE_2D, base_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, neutral);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (graph_) graph_->set_base_texture(base_tex_);
  }

  void do_render_locked_() {
    if (!egl_ || !graph_) return;
    egl_->make_current();
    do_render_locked_no_lock_();
    egl_->swap_buffers();
  }

  void do_render_locked_no_lock_() {
    if (!graph_) return;
    std::vector<Pass> passes;
    for (const auto& l : extras_) {
      Pass p;
      p.kind = l.kind;
      p.extra_tex = l.tex;
      p.opacity = l.opacity;
      p.blend_mode = l.blend;
      passes.push_back(p);
    }
    graph_->execute(passes, true);
    dirty_ = false;
  }

  int32_t view_id_;
  std::string source_path_;
  int32_t source_w_;
  int32_t source_h_;

  std::mutex mu_;
  std::unique_ptr<EglContext> egl_;
  std::unique_ptr<RenderGraph> graph_;
  GLuint base_tex_{0};
  GLuint lut_tex_{0};
  std::string lut_path_;
  float lut_intensity_{0};
  AdjustUniforms adjust_{};
  CropUniforms crop_{};
  std::vector<ExtraLayer> extras_;
  bool dirty_{true};
};

std::mutex g_sessions_mu;
std::unordered_map<int32_t, std::shared_ptr<SessionImpl>> g_sessions;

}  // namespace

std::shared_ptr<Session> create_session(int32_t view_id,
                                        const std::string& source_path,
                                        int32_t w, int32_t h) {
  std::lock_guard<std::mutex> lk(g_sessions_mu);
  auto s = std::make_shared<SessionImpl>(view_id, source_path, w, h);
  g_sessions[view_id] = s;
  return s;
}

std::shared_ptr<Session> get_session(int32_t view_id) {
  std::lock_guard<std::mutex> lk(g_sessions_mu);
  auto it = g_sessions.find(view_id);
  if (it == g_sessions.end()) return nullptr;
  return it->second;
}

void destroy_session(int32_t view_id) {
  std::lock_guard<std::mutex> lk(g_sessions_mu);
  auto it = g_sessions.find(view_id);
  if (it == g_sessions.end()) return;
  it->second->surface_destroyed();
  g_sessions.erase(it);
}

// Internal helpers used by jni_bridge / other cpp modules.
std::shared_ptr<SessionImpl> session_impl(int32_t view_id) {
  std::lock_guard<std::mutex> lk(g_sessions_mu);
  auto it = g_sessions.find(view_id);
  if (it == g_sessions.end()) return nullptr;
  return it->second;
}

}  // namespace minis::imgedit
