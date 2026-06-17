# featureorbug — Enterprise Video Editor Enhancement Log

Iterative enterprise-grade improvements to the Flutter video editor at `example/lib/editor/`. One focused improvement per iteration. Each entry: date, category, summary, files touched, rationale.

---

## 2026-06-07 — Pro Shuttle Keys (J/K/L) + Numeric Speed Presets

**Category:** feature / enterprise polish
**Status:** shipped
**Files:** `example/lib/editor/editor_screen.dart`

### What

Industry-standard NLE shuttle controls for keyboard playback rate, matching Avid Media Composer / Premiere Pro / DaVinci Resolve / Final Cut Pro conventions.

- **L** — shuttle forward, cycling rate up the ladder `1× → 1.5× → 2× → 4× → 8×`
- **J** — shuttle slower, cycling down `1× → 0.5× → 0.25× → 0.125×`
- **K** — stop shuttle; restores playback rate to `ed.clipSpeed` and pauses
- **1–5** — direct speed presets: `0.25× / 0.5× / 1× / 2× / 4×`

While shuttle is active, a cyan-bordered pill overlay shows the current rate near the top of the preview with an icon (▶▶ fast / 🐌 slow). The pill disappears when K is pressed or `_shuttleStop()` runs.

### How

State fields added to `_VideoEditorScreenState`:
- `_shuttleUpLadder`, `_shuttleDownLadder` (const ladders)
- `_shuttleRate` (current effective rate)
- `_shuttleActive` (whether pill should render)

Methods: `_nextShuttleUp`, `_nextShuttleDown`, `_shuttleSet`, `_shuttleUp`, `_shuttleDown`, `_shuttleStop`. All apply rate via `_ctrl.setPlaybackSpeed(rate)`, auto-start playback if paused, fire `HapticFeedback.selectionClick()`.

`_onKey` extended with J/K/L/digit1..digit5 branches. `_ShortcutsOverlay._rows` updated with three new entries documenting the bindings. Pill widget `_ShuttlePill` appended at end of file (uses theme `kAccentCyan`, tabular figures for stable digit width).

### Why

- All pro NLEs use J/K/L; users coming from Premiere/FCP/DaVinci/Avid expect it.
- Existing arrow-key frame stepping was the only fast-playback control; no way to preview at 2× or 4× without diving into the speed sheet (which permanently modifies `clipSpeed`).
- Numeric 1–5 covers the common review speeds without a menu.
- Shuttle is non-destructive: it does not push undo, does not mutate `ed.clipSpeed`, restores cleanly on K.

### Conflicts checked

- Bare digits 1–5 do not collide with any existing shortcut; do not fire inside focused text fields (Focus tree intercepts before reaching `_onKey`).
- J/K/L do not collide with any existing shortcut.
- `setPlaybackSpeed` already in use at line 1022 (`_doSpeed`), so platform support confirmed.
- Pill overlay placed in top-level Stack with `IgnorePointer`, will not block touch.

### Next iteration candidates

(ordered roughly by impact for future iterations of this loop)

1. **Timeline markers / chapters** — `M` to drop marker at playhead, `N`/`P` to jump, list sheet for edit/delete. Touches state + project_io + timeline + screen (≈4 files).
2. **Frame-accurate timecode HH:MM:SS:FF** — pro display using `ed.frameRateHint`; replaces the 4 duplicated `_fmt(ms)` helpers across `editor_screen.dart` and `editor_timeline.dart`.
3. ~~**Loop-region playback** — `I` mark in, `O` mark out, `Shift+L` toggle loop; visual shaded region on timeline.~~ → shipped 2026-06-07 iter 2.
4. **Voiceover dispose leak** — `editor_panels.dart:703` `_rec.stop()` fire-and-forget; await before `super.dispose()` (bug, from investigator pass).
5. **Crash-recovery prompt** — currently auto-restores; pro behavior offers explicit "Keep edit / Start fresh" with clip+overlay counts.
6. **Export filename in success toast** — `editor_screen.dart:1540` shows raw path; extract basename for `"Exported: video.mp4"`.
7. **Export presets library** — save/recall named export configs (resolution + bitrate + format).
8. **Multi-select on timeline** — shift-click for batch delete/move/duplicate.
9. **Keyframes for overlay transform/opacity** — animate stickers/text over time.

---

## 2026-06-07 — Loop-Region Playback (I / O / [ / ])

**Category:** feature / enterprise polish
**Status:** shipped
**Files:** `example/lib/editor/editor_screen.dart`

### What

Pro NLE loop-region playback for review/refinement of a sub-segment without committing trims. Industry standard in Premiere/FCP/DaVinci.

- **I** — mark loop IN at current playhead (clears OUT if it would invert)
- **O** — mark loop OUT at current playhead (rejects if ≤ IN)
- **[** — toggle loop ON/OFF (no-op with helpful toast if IN+OUT not yet set)
- **]** — clear loop (IN, OUT, enabled all reset)

When loop is enabled and playhead crosses OUT during playback, position ticker seeks back to IN automatically. Non-destructive: does not push undo, does not mutate `EditorState`, ephemeral to the screen lifecycle.

A second pill (`_LoopPill`) renders below the shuttle pill showing `IN → OUT` timestamps. Cyan border + loop icon when active; amber border + `[]` icon + "OFF" tag when set but not enabled. Auto-positions below `_ShuttlePill` when both are visible (top offset 96 vs 60).

### How

State fields in `_VideoEditorScreenState`:
- `int? _loopInMs`, `int? _loopOutMs`, `bool _loopEnabled`

Methods: `_setLoopIn`, `_setLoopOut`, `_toggleLoop`, `_clearLoop`, plus a local `_fmtShortMs` (MM:SS) helper used by both the pill and toasts.

`_startPositionTicker` extended with one branch: when `_loopEnabled && in != null && out != null && out > in && ms >= out`, fires `unawaited(c.seekTo(loopIn))`. The existing dedupe in `positionNotifier` keeps cost low.

`_onKey` adds I, O, BracketLeft, BracketRight branches. `_ShortcutsOverlay._rows` extended with two new entries. `_LoopPill` widget appended at file end.

### Why

- Frequent enterprise use case: tighten a transition or audio cue without scrubbing repeatedly.
- Pairs with the shuttle keys from iter 1: loop a region at 0.5× to study, then K to reset.
- Ephemeral by design — loop boundaries do not persist; trimming a clip should still go through the destructive Trim flow with undo.
- BracketLeft/BracketRight chosen over `Shift+L` (shift modifiers awkward on phones with attached keyboards) and to avoid collision with `L` (shuttle up).

### Conflicts checked

- I/O bare keys — no existing binding. No collision with text fields (Focus tree gates `_onKey`).
- `[` `]` keys — no existing binding.
- Pill stacking — `top: _shuttleActive ? 96 : 60` keeps both visible without overlap.
- `dart analyze` clean.

### Next iteration candidates (refreshed)

1. **Timeline markers / chapters** — `M` drop marker, `N`/`P` jump, sheet to edit/delete. Persisted via project_io.
2. **Frame-accurate timecode HH:MM:SS:FF** — centralize the 4 duplicated `_fmt(ms)` helpers; use `ed.frameRateHint`.
3. **Voiceover dispose leak** — `editor_panels.dart:703`.
4. **Crash-recovery prompt** — keep/discard dialog on `_init` restore.
5. **Export filename in success toast** — basename only.
6. **Export presets library** — named save/recall.
7. **Multi-select on timeline** — batch ops.
8. **Keyframes for overlay transform/opacity**.
9. **Loop-region visual on timeline ruler** — render shaded band in `editor_timeline.dart` to complement the pill from this iteration.

---
