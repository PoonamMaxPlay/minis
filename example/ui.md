# Video Editing App — Complete UI Specification

Source: synthesized from 15 screenshots in `editscreenui/` (analyzed via Gemini) + screen-recording `uivideo/1000211364.mp4` analyzed across 8 parallel Gemini passes (layout, motion, controls, colors, sheets, timeline, preview, state). App resembles CapCut-style mobile video editor. Mobile portrait orientation, dark theme, cyan primary accent.

---

## 0. Design System

### Color Palette
| Token | Hex (approx) | Use |
|---|---|---|
| `bg.primary` | `#000000` | App background, headers |
| `bg.surface` | `#1A1A1A` – `#1E1E1E` | Panels, bottom sheets, pill buttons |
| `bg.surface-2` | `#2A2A2A` | Inset cards (Cover, Mute, track containers) |
| `text.primary` | `#FFFFFF` | Labels, icons, active text |
| `text.secondary` | `#AAAAAA` | Subtitles, descriptions, inactive labels |
| `accent.primary` | `#00E5FF` / `#00CCFF` (cyan/teal) | Export, Generate, active tab underline, slider active track, selection highlight |
| `accent.pro` | linear-gradient(purple → pink) | "Pro" badges |
| `state.new` | cyan pill | "New" / "Free" badges |

### Typography
- Family: clean sans-serif (Roboto / system default)
- Weights: Regular (labels), Bold (primary CTAs like "Export", "Generate")
- Sizes: small (10–12sp) for timeline labels and meta, medium (14sp) for tool labels, larger (16–18sp) for sheet titles and CTA text

### Shape & Spacing
- Rounded pills/buttons (high corner radius, ~20–24px for CTA, ~12px for cards)
- Touch targets sized for thumb reach; primary controls in bottom third
- Consistent 16px padding inside panels
- Vertical stack: Header → Preview → Preview Controls → Timeline → Contextual tool panel → Bottom nav

### Iconography
- White, minimalist line-art icons throughout
- Active icon/state indicated via filled color, cyan underline, or solid white border

---

## 1. Top Header Bar (persistent across editor)

Fixed full-width, solid black background, sits below OS status bar.

| Component | Position | Style | Function |
|---|---|---|---|
| **Close (X)** | Top-left | White line icon | Exit editor / discard project |
| **Search** | Left of center, right of Close | White magnifying glass | Search assets, effects, tools |
| **Resolution Selector** | Right of center | Dark grey pill, white text "540P" + downward chevron | Opens export resolution/quality menu |
| **Export Button** | Top-right corner | Cyan/teal rounded rectangle, bold black "Export" | Renders + saves final video. Primary CTA |

---

## 2. Video Preview Area

Occupies upper third-to-half of screen.

- **Canvas:** centered, displays current frame. Aspect ratio 9:16 by default (vertical/mobile)
- **Overlays:** text layers visible on canvas ("capybara ?!" example)
- **Instructional overlay (contextual):** small semi-transparent white text e.g. "Use both fingers to resize your video" — appears when in Ratio/transform modes; auto-hide after ~3 s or first gesture
- **Background of preview area:** black to make content pop
- **Snap guidelines (NEW from video):** when dragging an overlay, thin cyan horizontal/vertical lines appear momentarily as overlay center aligns with canvas center or a 10 % safety-zone edge
- **Canvas shrink behavior:** preview area animates ~12 % shorter (250 ms ease-in-out) when a complex configuration sheet (Filters/Text/Adjust) opens, gaining vertical space for the drawer

---

## 3. Preview Control Bar

Directly below preview. Single horizontal row.

| Control | Position | Style | Function |
|---|---|---|---|
| **Fullscreen Toggle** | Far left | White corner-bracket / expand icon | Switch preview to full-screen |
| **Play / Pause** | Center | Large white right-pointing triangle (Play) / pause bars when playing | Toggle timeline playback |
| **Layer / Snap / Audio ON toggle** | Right of center | Stacked squares icon w/ "ON" badge | Toggle multi-layer view or snapping/audio guides |
| **Undo** | Right | White counter-clockwise curved arrow | Revert last action |
| **Redo** | Far right | White clockwise curved arrow | Re-apply reverted action |

---

## 4. Timeline & Track Area

Center-lower section. Horizontal scroll. Vertical white **playhead** fixed in horizontal center indicating current frame — timeline tracks scroll behind it during playback and manual scrubbing.

### Time Header
- **Time Display (top-left of timeline):** white sans-serif `MM:SS / MM:SS` (e.g. `00:01 / 00:33`) showing current vs total
- **Time Ruler:** grey ticks + numeric labels (00:00, 00:02, 00:04, …). Tick spacing dynamic with zoom — major ticks every 1 s or 5 s, minor every 100 ms when zoomed in
- **Snap magnetism:** ~5–10 px pull when playhead or clip edge is near a tick

### Track Headers (left static column, 48–64 px wide)
| Item | Style | Function |
|---|---|---|
| **Mute clip** | Dark grey square w/ white speaker icon (slash when muted) + "Mute clip" label | Toggle audio for video track |
| **Cover** | Dark grey square w/ thumbnail + pencil overlay + "Cover" label | Choose video thumbnail (cover frame) |
| **Audio header** | Music-note icon (visible when audio track exists) | Identifies audio track |
| **Text header** | "T" icon (visible when text track exists) | Identifies text track |
| **Lock / Visibility** (optional) | Padlock / eye icon per track | Prevent edits or hide overlays |

### Tracks
| Track | Default state | Style |
|---|---|---|
| **Main Video Track** | Always present, filled with thumbnails | Horizontal strip of video frames; trailing white "+" square button appends clips. Magnetic timeline — no gaps. |
| **Audio Track** | Placeholder when empty: `+ Add audio` w/ music-note icon | Full-height PCM waveform once populated. Distinct color per type (music vs voiceover). Faint white line overlays = volume envelope |
| **Text Track** | Placeholder when empty: `+ Add text` w/ "T" icon | Colored rectangular segments showing text snippet or sticker glyph |
| **Sticker / Overlay Track** | Hidden until added | Same colored-segment style; z-order = vertical stack order |

### Clip Selection (NEW from video)
- **Single tap** on a clip → 2 px white border around it, **trim handles** (thick white vertical bars) at start/end
- **Drag a handle** → live updates `inMs` / `outMs`, haptic pulse on snap to playhead or other clip edge
- **Long-press + move** → clip "lifts" (1.05× scale + shadow), other clips fluidly shift to make room
- Selecting a clip swaps the Bottom Nav for **Contextual Edit Tools** (split, speed, animation, delete, volume, mask, etc.)

### Transitions Between Clips (NEW from video)
- Small white square / bow-tie icon between adjacent clips
- Tap → opens Transition Picker sheet (Crossfade, Slide, Push, Glitch, Zoom & Dissolve)
- Selected transition visualized by overlapping thumbnails of the two clips
- Real-time shader preview during playhead scrub through the overlap

### Pinch-to-Zoom Timeline (NEW from video)
- Two-finger horizontal pinch on timeline → expands/contracts time scale
- Zoom anchor = current playhead position
- Range: ~1 frame / px (max zoom-in) to ~10 s / px (max zoom-out)

### Playhead
- Solid vertical white line bisecting timeline; fixed horizontal-center position, tracks scroll past it
- Subtle pulse on every frame-snap during scrub (simulates haptic)

### Contextual Toast / Suggestion
- Floating dark rounded pill above bottom nav, e.g. "Try noise reduction for clearer audio"
- Left: small wave/feature icon; Right: `>` chevron + duration estimate (e.g. "12s"); Trailing: close (×)
- Function: proactive AI/assistive suggestion

---

## 5. Bottom Navigation (Root Tool Categories)

Bottom-most, full-width, solid black, 7 root categories. White line icons + small white labels under each. Selected category highlights and reveals a sub-menu (Section 6+).

| Order | Tool | Icon | Opens |
|---|---|---|---|
| 1 | **Edit** | Scissors | Trim, split, speed (clip-level edits) |
| 2 | **Audio** | Music note / waveform circle | Audio sub-menu (Section 6.1) |
| 3 | **Text** | "T" / "A" in square | Text sub-menu (Section 6.2) |
| 4 | **Effects** | Star / magic wand | Effects sub-menu (Section 6.3) |
| 5 | **Overlay** | Picture-in-picture / stacked squares | Overlay sub-menu (Section 6.4) |
| 6 | **Captions** | Subtitle box | Captions sub-menu (Section 6.5) |
| 7 | **Filters** | Three overlapping circles (Venn) | Filters / Adjust panel (Section 6.6) |

Additional tools surfaced contextually: **Ratio** (Section 6.7), **Background** (Section 6.8), **Stickers** (Section 6.9).

Sub-menu pattern:
- Left edge: white `<` chevron — back to root nav
- Horizontal scrollable row of tool icons + labels
- Some items carry badges: `New` (cyan pill), `Free` (cyan pill), `Pro` (purple-pink gradient pill)

### Commit / Cancel State (NEW from video)
When a configuration sheet (Filters, Adjust, Text style, Ratio, Background) is open, the bottom row swaps from root categories to a **two-button Commit / Cancel bar**: large `✗` (left) discards, large `✓` (right, cyan) commits. Returning closes the sheet and restores the root nav.

---

## 6. Sub-Menus

### 6.1 Audio Sub-Menu
Tools (left-to-right):
- **Extract** — pull audio from another video
- **Sounds** — open music/sound library
- **Sound FX** — sound-effects library
- **Record** — voiceover capture
- **Text to audio** — TTS voice generation from typed text
- **Copyright** — check music copyright clearance

Style: white outline icons, label below in small white text.

### 6.2 Text Sub-Menu
Tools:
- **Options** (square w/ lines) — generic clip/text options
- **Stickers** (smiley) — graphic stickers
- **Draw** (pencil) — freehand draw over video
- **Text template** ("A" in frame) — styled text presets
- **Text to audio** (waveform bars) — TTS from typed text
- **Auto lyrics** (music note w/ lines) — auto-generate lyric overlays

### 6.3 Effects Sub-Menu
Categories:
- **Video Effects** (magic wand / stars) — visual filters and transitions
- **Body Effects** (smiley w/ sparkles) — AI body/face effects
- **Photo Effects** (cube / 3D) — still-image / 3D transforms, badged **"New"** in cyan pill

### 6.4 Overlay Sub-Menu
Primary action:
- **Add overlay** — center; square `+` icon w/ "Add overlay" label. Opens picker for Text, Stickers, Pictures.

### 6.5 Captions Sub-Menu
Tools:
- **Enter captions** (text box + plus) — manual entry
- **Auto Captions** (square w/ brackets) — opens "Auto captions" bottom sheet (Section 7.1)
- **Caption templates** ("CC" in square) — styled preset templates
- **Auto lyrics** (note + CC) — lyric-aware captions
- **Import captions** (download/import icon) — load .srt/.vtt

### 6.6 Filters / Adjust Panel
Two-level tab structure:

**Primary tabs (above sub-tabs):**
- `Filters` (inactive — grey)
- `Adjust` (active — white bold, cyan underline)
- `✓` checkmark at far right — confirm + close

**Sub-tabs (under primary):**
- `Smart` (inactive — grey)
- `Customize` (active — white)

**Adjustment carousel (horizontal scroll):** circular outlined buttons w/ label
| Tool | Icon |
|---|---|
| Brightness | Sun w/ rays |
| Contrast | Half-filled circle (selected state shown in example) |
| Saturation | Water drop |
| Brilliance | Dotted sun |
| Sharpen | Upward triangle |
| Clarity | Hollow triangle — `Free` badge |

**Intensity Slider:** horizontal grey track, large white circular thumb centered (0 baseline). Drag to adjust selected parameter.

**Footer:**
- **Reset** (bottom-left) — white text + circular CCW arrow; reverts Customize values to default

### 6.7 Ratio Tool
Horizontal scroll of aspect-ratio presets:
| Preset | Icon hint | Notes |
|---|---|---|
| Original | Generic frame | Selected: solid white rounded border |
| 9:16 | TikTok-style | Vertical |
| 16:9 | YouTube-style | Landscape |
| 1:1 | Instagram-style | Square |
| 4:3 | Landscape | |
| 3:4 | Portrait | |
| 5.8" | Narrow portrait | Device-shape preview |

Label "Ratio" centered at bottom. Checkmark bottom-right applies + closes. While active, preview shows "Use both fingers to resize your video" overlay.

### 6.8 Background Tool
Tools (when background subpanel open):
- **Color** (square + droplet) — solid color background
- **Image** (landscape icon) — image background
- **Blur** (circle) — blur background fill

Preview shows resize instruction overlay.

### 6.9 Stickers / GIPHY Panel
Bottom-sheet panel.

**Tab bar (top of sheet):** `Stickers` | `GIPHY`. Active tab gets cyan underline. White `✓` at far right confirms + closes.

**Search field:** wide dark-grey rounded rect, magnifying glass icon, placeholder "Search GIPHY".

**Content filter tabs (under search):** `Stickers` | `GIFs` — bold white text, no background (secondary tabs).

**Empty / Error state (centered):** circular Refresh icon + text "No internet connection. Connect to the internet and try again."

**Footer indicator:** neon cyan squiggle (brand mark / swipe handle).

---

## 7. Modal / Bottom-Sheet Overlays

Global behavior: top-left/top-right corner radius 16 px, scrim dim ≈ 50 %, dismissed by tap outside or explicit Done/✓/✗/×. Slide-up open ~250 ms cubic-bezier(0.22, 1, 0.36, 1).

### 7.1 Auto Captions Sheet
Dark-themed bottom sheet over dimmed editor.

**Header:** centered bold white "Auto captions" + right-aligned `×` close.

**Rows (dark grey rounded cards, ~8–12px radius):**

| Row | Left icon | Label | Trailing value |
|---|---|---|---|
| Generate from | Focus / scan brackets | "Generate from" | "Video >" (grey, opens picker) |
| Spoken language | "A / 文" translate icon | "Spoken language" | "Auto detect >" |

**Templates section (larger card):** "CC" header icon + "Templates" label. Empty/loading area with centered **Refresh** circular-arrow button to reload caption-style templates.

**Advanced options (Pro):** dark grey row, `Pro` gradient badge (purple→pink), "Advanced options" label, trailing `v` chevron (expandable).

**Bottom CTA:** full-width cyan rounded rectangle, bold black **"Generate"** — triggers AI caption generation.

### 7.2 Export Settings Sheet
Dark grey panel covering upper half over dimmed editor. Top header retains "video" label (top-left), Resolution pill, and Export CTA.

| Section | Label | Description | Control | Notes |
|---|---|---|---|---|
| Resolution | "Resolution" + ⓘ help | "Normal definition - uses less space, better for sharing" | Step slider: `480p / 540p / 720p / 1080p / 2K/4K` | Cyan filled track up to thumb, grey beyond. Large white circular thumb. Default 540p |
| Frame rate | "Frame rate" | "Smoother playback" | Step slider: `24 / 25 / 30 / 50 / 60` | Default 30 |
| Optical flow | "Optical flow" | "Make video playback smoother." + cyan "Example" link/icon | Toggle switch (right-aligned) | Off by default (outline) |
| Bitrate (Mbps) | "Bitrate (Mbps)" | "Recommended for this video (7)" | Continuous slider: `5 / 10 / 20 / 50 / 100` | Cyan track, white thumb |

**Footer info:** "Estimated file size: 28 MB" — muted grey, centered below sliders. Updates reactively as user changes Resolution / Bitrate.

### 7.3 Transition Picker Sheet (NEW from video)
Opens when tapping the transition icon between two timeline clips.

- **Grid:** square thumbnails — Crossfade, Slide, Push, Zoom & Dissolve, Glitch, etc.
- **Duration slider:** 0.2 – 2.0 s, cyan track
- **Apply to all:** trailing toggle to apply to every cut in the timeline
- **Preview:** real-time shader preview in the canvas as the picker scrolls

### 7.4 Animation Sheet (NEW from video)
Triggered from Edit → Animation on a selected clip. Three sub-tabs: **In** / **Out** / **Group**.
- Horizontal scroll of preset animations (Fade, Slide, Zoom, Spin, Mosaic)
- Duration slider underneath
- ✓ commits, ✗ cancels

---

## 8. State & Interaction Rules

- **Active vs inactive tab:** active = white bold + cyan underline; inactive = grey, no underline
- **Active vs inactive icon:** active = filled / cyan tint; inactive = white outline
- **Selection highlight (preset tiles, ratio, etc.):** solid white rounded border around tile
- **Primary CTAs (Export, Generate):** always cyan background + bold black text + high corner radius — never grey out unless action invalid
- **Pro features:** purple→pink gradient `Pro` pill — clicking unauthenticated should route to subscription paywall
- **New / Free tags:** cyan pill on top-right of tool icon
- **Empty states:** centered icon + single-line white text + Refresh / Retry circular-arrow button when remote
- **Toasts / Suggestions:** floating dark pill above bottom nav, dismissible with `×`. Slide up from bottom, auto-dismiss after 2 s
- **Dimming overlay:** when a bottom sheet opens (Export, Auto captions), background editor dims ~40–60%
- **Busy spinner:** semi-transparent black overlay (`0x99000000`) + cyan `CircularProgressIndicator` + status label (e.g. "Exporting…")
- **Success feedback:** floating pill with green ✓ briefly after successful export, caption generation, copyright clearance
- **Undo / Redo:** white (active) vs `white24` (disabled). Toggling history state animates the opacity ~150 ms
- **InkWell press:** subtle 0.98× scale-down + opacity flash, ~100 ms

---

## 9. Layout Hierarchy (top → bottom)

```
┌─────────────────────────────────┐
│  OS Status Bar (time, signal)   │
├─────────────────────────────────┤
│  Top Header: X  🔍   540P▾ [Export] │
├─────────────────────────────────┤
│                                 │
│        Video Preview Area        │
│      (canvas + overlays)         │
│                                 │
├─────────────────────────────────┤
│  ⤢   ▶   ▢ON  ↶  ↷               │
├─────────────────────────────────┤
│  00:01/00:33   00:00  00:02  …   │
│ ┌──┬──┬──────────────────────┐  │
│ │🔇│Cv│ [video thumbs] [+]    │  │ ← playhead │
│ │  │  │ + Add audio           │  │
│ │  │  │ + Add text            │  │
│ └──┴──┴──────────────────────┘  │
├─────────────────────────────────┤
│ (contextual tool sub-menu or    │
│  bottom-sheet overlay)          │
├─────────────────────────────────┤
│ Edit Audio Text Effects Overlay  │
│ Captions Filters                 │
└─────────────────────────────────┘
```

---

## 10. Implementation Notes for Flutter

- Build the editor as a `Scaffold` with `Stack` children: persistent header (top), preview + controls + timeline (center scroll/column), bottom nav (anchored bottom), and a slot for contextual sub-menu / bottom sheets above the bottom nav.
- Use `showModalBottomSheet` (or a custom animated `DraggableScrollableSheet`) for **Auto captions** and **Export Settings** sheets — both dim the background.
- Timeline = horizontally scrollable `CustomScrollView` with a `Stack`-positioned vertical playhead line; left track-header column is a `Row` partner that stays fixed.
- Theme: `ThemeData.dark()` extended with `colorScheme.primary = Color(0xFF00E5FF)`. Apply cyan to `ElevatedButton`, `Slider.activeTrackColor`, and tab indicators.
- Icons: prefer custom SVG line icons (most are outline glyphs) over Material defaults to match brand.
- Sub-menus follow uniform contract: leading `<` back chevron + horizontally scrollable list of `(icon, label, optional badge)`. Build as one reusable widget `ToolSubmenu(items: [...])`.
- Adjustment carousel = horizontal `ListView` of circular outlined `ToggleButton`s; selected item drives the intensity slider below.
- Badges (`Pro`, `New`, `Free`) = small `Positioned` pill in top-right corner of icon, rendered as `Container` with gradient or solid color and white label.

---

## 11. Overlay Selection & Handles (NEW from video)

When user taps an existing text / sticker / picture overlay on the canvas, a **bounding box** appears with four corner handles.

### Selection Ring
- 1.5 px solid white border, 8 px outer padding from content
- Brought-to-front (z-order shift) on selection
- Tap empty canvas → deselect, hide handles

### Corner Handles (12 px white-filled circles)
| Corner | Icon | Action |
|---|---|---|
| Top-Left | `×` | Delete overlay |
| Top-Right | Swap arrows | Mirror / flip horizontally |
| Bottom-Left | Pencil | Edit (text → keyboard, sticker → replace gallery) |
| Bottom-Right | Rotate arrows | Combined scale (drag toward/away from center) + rotate (drag in arc). Snaps to 0°/90°/180°/270° with haptic pulse |

### Snap Guides
- Drag-to-move emits cyan center-cross when overlay center crosses canvas center or any 10 % safety-zone edge
- Lines fade in 80 ms, fade out 200 ms after release

---

## 12. Motion & Animation Spec (NEW from video)

| Interaction | Duration | Easing |
|---|---|---|
| Bottom sheet open / close | 300 ms | `Cubic(0.22, 1, 0.36, 1)` |
| Sub-menu sideways switch | 250 ms | `Curves.easeInOutCubic` |
| Sub-menu items stagger-in | 30 ms per item | `Curves.easeOut` |
| Primary button tap | 100 ms down / 120 ms up | 0.95× scale + opacity 0.85 |
| InkWell ripple | 150 ms | default Material |
| Timeline boundary rubber-band | 400 ms | spring (high tension) |
| Clip lift (long-press) | 220 ms | 1.05× scale + 12 dp shadow |
| Playback start/stop latency | ≤ 50 ms | linear |
| Snap guide fade-in | 80 ms | linear |
| Toast / suggestion slide-up | 250 ms | `Curves.easeOut` |
| Busy overlay fade | 200 ms | linear |
| Success pill | enter 200 ms / hold 1500 ms / exit 200 ms | ease-in-out |

### Haptics (Android `HapticFeedback`)
- `lightImpact` on chip / button tap, snap guide hit, scrubbing frame-snap
- `selectionClick` on rotation 90° snap, slider division pass
- `mediumImpact` on successful commit (Export, Apply Filter)

---

## 13. Multi-Track Timeline Detail (NEW from video)

Beyond the existing flat track placeholder, the recording shows multi-track stacking:

### Audio Tracks
- Full-height PCM waveform (peak + RMS). Generate via native `extractWaveform` or Dart-side downsampling of decoded PCM
- Color-coded: cyan/blue for music, green/yellow for voiceover, magenta for SFX
- Volume envelope = thin white line atop waveform, draggable handles to keyframe gain

### Text & Sticker Tracks
- Stacked under main video. Each = colored segment (text = purple, sticker = orange, picture = blue)
- Segment label = text snippet or sticker glyph
- Drag horizontally to reposition `startMs` / `endMs`; drag vertically to reorder z-index

### Track Header Column Enhancements
- Per-track: mute toggle, lock (prevent edits), eye (hide from preview)
- Long-press header → reorder track vertically

---

## 14. Implementation Gap vs Current Editor

Cross-checking `example/lib/editor/` against the video, the deltas to close:

1. **Overlay selection ring + 4 corner handles** — `_TextsLayer` / `_StickersLayer` currently only support drag/scale; add tap-to-select state in `EditorState.selectedOverlayId`, render handles when selected.
2. **Canvas snap-guides** — emit cyan center cross during overlay drag.
3. **Clip selection + trim handles in timeline** — currently no per-clip selection; add `selectedClipId` to `EditorState`, render 2 px white border + drag handles.
4. **Transitions between clips** — add `TransitionType` to `ClipSegment`, render small square between clips, open Transition Picker sheet.
5. **Pinch-to-zoom timeline** — wrap `_TimelineBar` thumb-strip in `GestureDetector(onScaleUpdate:)`, scale `pxPerMs`.
6. **Multi-track audio waveform** — render PCM waveform under main strip; first pass can be amplitude-only.
7. **Commit/Cancel bottom-nav swap** — when a configuration sheet is open, render `_CommitCancelBar` instead of `_BottomNav`.
8. **Snap toggle wired to actual snapping logic** — toggle currently only flips state; gate snap-guide emission + magnetic-snap in handles on `ed.snapEnabled`.
9. **Haptic feedback** — wire `HapticFeedback.selectionClick` on snap, chip pick, slider tick.
10. **Smooth panel motion** — wrap `showModalBottomSheet` open transitions with the cubic curve from §12.
11. **Animation sub-menu** — add Edit → Animation entry opening a sheet with In/Out/Group tabs (dummy presets ok).
12. **Caption templates row** — currently shows centered Refresh; load a horizontal preset row (5 dummy styles).
13. **Success pill** — replace plain `_toast('Saved: $out')` after export with cyan-bordered pill + green ✓ that auto-fades.
14. **Magnetic timeline (no gaps)** — when a clip is deleted, neighbors slide together; animate the close.

These changes are scoped per file:
- `editor_state.dart` — add `selectedOverlayId`, `selectedClipId`, `TransitionType`, `ClipAnimation` fields.
- `editor_screen.dart` — selection rings, handles, snap guides, clip trim handles, transition icons, pinch-zoom, commit-cancel bar.
- `editor_panels.dart` — Transition Picker sheet, Animation sheet, caption templates row, success pill.
- New util `editor_waveform.dart` — downsample PCM → amplitude array for audio track render.

---

## 15. Multi-Track Timeline Behaviour

The timeline is a vertically stacked, horizontally scrollable surface. The main video strip pins to the top; every other track stacks below it inside the scroll container.

### Vertical stacking order

| Z | Track | Row height | Notes |
|---|-------|------------|-------|
| 0 (top) | Video (main) | thumb-strip height | Single row, frame thumbnails |
| 1..N | Audio tracks | 24 px each | One row per audio clip group, waveform segments |
| N+1 | Text | 24 px | Caption / title snippets as rounded segments |
| N+2 (bottom) | Sticker / overlay | 24 px | Sticker, shape, GIPHY overlay segments |

Each non-video row is a dark surface (`#1A1A1A`) with rounded (4 px radius) segments per item. Audio segments render a waveform; text segments render a truncated label; overlay segments render a thumbnail glyph.

### Segment drag handles

- Two 6 px wide white handles per selected segment: left handle drives `startMs`, right handle drives `endMs`.
- Drag updates the segment in real time (no commit-on-release).
- Handles snap to the playhead with `HapticFeedback.lightImpact` on contact.
- Minimum segment width enforced at 60 ms; further drag past the opposing handle is clamped.

### Horizontal scrubbing

- Dragging in empty timeline area moves the playhead. `positionMs += dragDeltaPx / timelinePxPerMs`.
- Frame-precise: rounded to nearest frame at active project fps.
- Active drag suppresses auto-playback; release resumes prior play/pause state.

### Horizontal pinch-zoom

- `onScaleUpdate` scales `timelinePxPerMs` clamped to `[0.01, 1.0]`.
- The playhead acts as the zoom anchor: its on-screen x is preserved across the scale; surrounding content reflows around it.

### Vertical scroll

- When `videoRow + audioCount + textRow + overlayRow > 3` visible rows, the track stack becomes vertically scrollable inside a fixed-height container (default 168 px).
- Video row stays pinned (sticky header); audio/text/overlay rows scroll beneath it.

### Snap-magnetism

- 6 px snap radius (in screen px) to: the playhead, any clip start/end on the video row, and any other segment edge on the same or adjacent track.
- On snap engage: `HapticFeedback.lightImpact`; cyan 1 px vertical guide rendered until release.

### Visual feedback per segment

- **Tap** — selects segment; renders 1 px white border + handles. Fires `HapticFeedback.selectionClick`.
- **Long-press** — lifts segment (scale 1.05, drop shadow) for reorder within its track row.
- **Deselect** — tap outside any segment or press the global cancel chip.

### Conventions

- All measurements in logical pixels (`dp`).
- Haptics: `lightImpact` on snap engage, `selectionClick` on segment select / handle pickup.
- Colors inherit the editor dark palette; white = `#FFFFFF` at full opacity for handles and selection borders.
