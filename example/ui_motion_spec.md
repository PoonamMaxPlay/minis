# Motion & Animation Specification: Mobile Video Editor

This document outlines the animations, transitions, and micro-interactions observed in the reference recording `@1000211364.mp4`.

## 1. Core Panel Transitions

### 1.1. Tool Panel (Bottom)
- **Action:** Opening the main toolset or an edit sub-panel.
- **Direction:** Slide-in from bottom to top.
- **Duration:** 300ms.
- **Easing:** `CubicBezier(0.22, 1, 0.36, 1)` (Decelerate/EaseOutQuint).
- **Feedback:** Background dimming (overlay) with 200ms fade-in.

### 1.2. Sub-Menu / Library (Lateral)
- **Action:** Transitioning from main toolset to a specific library (e.g., Stickers, Filters).
- **Direction:** Slide-in from right to left.
- **Duration:** 250ms.
- **Easing:** `CubicBezier(0.4, 0, 0.2, 1)` (Standard EaseInOut).

## 2. Timeline & Playhead Motion

### 2.1. Playback
- **Playhead Motion:** Fixed center position; timeline moves underneath.
- **Frame Rate:** 60fps target for smooth scrubbing.
- **Start/Stop:** Near-instantaneous (≤50ms) with a slight "catch-up" acceleration on start.

### 2.2. Manual Scrubbing (Interaction)
- **Drag Feedback:** Direct 1:1 mapping between finger movement and timeline offset.
- **Snapping:** Playhead "magnetically" snaps to clip boundaries, transitions, and markers.
- **Snap Animation:** 100ms snap-to-point with a subtle haptic-like UI pulse.

### 2.3. Clip Reordering (Drag & Drop)
- **Lift Phase:** Long-press (400ms) triggers 1.05x scale + elevation (shadow).
- **Collision Phase:** Neighboring clips slide aside with a `Spring(stiffness=250, damping=25)` animation to create a gap.
- **Drop Phase:** Clip scales back to 1.0x and shadow fades over 150ms.

## 3. Button & Micro-Interactions

### 3.1. Primary Action Buttons
- **Touch Down:** Scale to 0.95x, opacity shift to 0.8.
- **Touch Up:** Scale back to 1.0x with a subtle "pop" (overshoot) to 1.02x before settling.
- **Duration:** 100ms (down), 150ms (up).

### 3.2. Ripple/Highlight Effects
- **Selection:** Active tool icon glows with a primary color tint and a subtle pulsing animation (±2% scale).
- **Track Interaction:** Tapping a clip on the timeline adds a 2px high-contrast border with a 150ms fade-in.

## 4. Video Transitions (Compositor Shaders)

### 4.1. Cross-Fade (Standard)
- **Type:** Linear Opacity Mix.
- **Duration:** 500ms (default).
- **Timing:** Centered on the clip boundary.

### 4.2. "Push" Transition
- **Type:** Translation.
- **Direction:** Clip A is pushed out by Clip B from right to left.
- **Easing:** `EaseInOutQuart`.
- **Duration:** 400ms.

### 4.3. "Zoom & Dissolve"
- **Type:** Scale + Opacity.
- **Effect:** Clip A scales up to 1.2x while fading out; Clip B fades in starting from 0.8x and settling to 1.0x.
- **Duration:** 600ms.

## 5. Scrubbing Feedback (Micro-Motion)
- **Vibration:** Visual representation of haptic feedback on setiap frame snap or critical point.
- **Playhead Elasticity:** If scrubbing past the start/end of the timeline, the timeline exhibits a "rubber-band" resistance and snap-back.
