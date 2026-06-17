# Minis image-editor Metal shaders

Metal Shading Language (`.metal`) sources consumed by
`ImageEditMetalRenderer`. Build into a `default.metallib` via the
Xcode project's Metal compile phase; the renderer loads functions by
name at session init.

Planned files:

- `filters.metal` — channel/curve adjustments, brightness, contrast,
  saturation, temperature, tint, exposure, highlights/shadows,
  whites/blacks, vibrance, sharpen, clarity, dehaze.
- `tone_curve.metal` — RGB + per-channel Bezier curve evaluation.
- `blur.metal` — Gaussian (separable), motion, radial; the engine
  prefers `MPSImageGaussianBlur` for hot-path Gaussian.
- `lut.metal` — 3D LUT sampler (input is a `MTLTextureType.type3D`
  built from the parsed `.cube`).
- `vignette.metal` — radial darkening / lightening.
- `grain.metal` — film grain.
- `glitch.metal` — RGB split, chromatic aberration, glitch.
- `liquify.metal` — warp-grid sampler.
- `heal.metal` — patch-match composite pass.
- `mask_composite.metal` — blend-mode composite for layers.
- `text.metal` — SDF text rendering with stroke + shadow.
- `sticker.metal` — sticker compositing.

Real implementation lives outside the skeleton; the renderer file
`ImageEditMetalRenderer.swift` references the planned function names
via `MTLLibrary.makeFunction(name:)` once `default.metallib` ships.
