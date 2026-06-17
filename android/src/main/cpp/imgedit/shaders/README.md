# Minis image-editor GLSL shaders

GLSL ES 3.0 fragment shaders consumed by `pipeline.cpp`. Each `.glsl` file
exports a single `main()` and is compiled at session init.

Planned files:

- `base_image.frag.glsl` — base sampler with sRGB → linear conversion.
- `adjustments.frag.glsl` — exposure, brightness, contrast, highlights,
  shadows, whites, blacks, saturation, vibrance, temperature, tint,
  sharpen, clarity, dehaze.
- `tone_curve.frag.glsl` — RGB + per-channel Bezier curve evaluation.
- `lut3d.frag.glsl` — 3D LUT sampler.
- `blur_gaussian.frag.glsl` — two-pass Gaussian (horizontal + vertical).
- `blur_radial.frag.glsl` — radial blur.
- `vignette.frag.glsl` — radial darkening / lightening.
- `grain.frag.glsl` — film grain.
- `glitch.frag.glsl` — RGB split, chromatic aberration, glitch.
- `liquify.frag.glsl` — warp-grid sampler.
- `heal.frag.glsl` — PatchMatch composite pass.
- `mask_composite.frag.glsl` — blend-mode composite for layers.
- `text.frag.glsl` — SDF text rendering with stroke + shadow.
- `sticker.frag.glsl` — sticker compositing.

Each shader is loaded via `pipeline.cpp::load_shader` which reads the
file from the APK asset bundle at `assets/luts/shaders/` and caches the
compiled program by `(file, defines)` tuple.
