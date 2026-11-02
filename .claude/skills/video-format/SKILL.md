---
name: video-format
description: Specs and recipes for the background ("AI") video that someone films themselves over in VideoFilmer, covering size, frame rate, safe areas for each layout, timing scenes to the script, music, and how to render it (native Swift template, HyperFrames, or Remotion) and check the result. Use when creating, rendering or fixing a video to be used in VideoFilmer.
---

# The background video

VideoFilmer plays this video while the presenter reads the script, and composites both into one frame (camera on top, in a corner, side by side, or voice-over only). The video must fit **every** layout and stay **in sync with the script's timings**.

## Spec

| | Default (vertical) | Horizontal | Square |
|---|---|---|---|
| Size | **1080 × 1920** | 1920 × 1080 | 1080 × 1080 |
| Frame rate | **30 fps** | 30 | 30 |
| Codec | **H.264 MP4**, ~10 Mbps | | |
| Audio | optional music bed, **AAC stereo**, normalised to ~−1 dBFS peak | | |
| Length | last script line + its duration + ~1 s | | |

The music goes in at full level: VideoFilmer plays it under the voice (35% by default) and the level can be changed per take afterwards.

## Safe areas (vertical 1080 × 1920)

- **Split layouts** ("Me top, video bottom" / "Video top, me bottom") show only the **middle band y = 480–1440** of the video (it's cropped to fill half the frame). **Everything that matters goes in that band.** Use the top and bottom areas for background colour and decoration only.
- **"Me in a corner"** puts a ~410 px round/square camera bubble in a corner, by default the **top right** (x ≈ 630–1040, y ≈ 40–450). Keep text out of that corner. The centred wordmark at y≈200 gets partly covered, so for corner-heavy videos put the wordmark **top-left** or lower.
- **Voice-over only / full screen**: the whole frame shows.
- Keep 70 px side margins for text.

## Timing scenes to the script

1. Take each script line's `[m:ss.s]` start: **one scene per line** (or per 1–2 lines).
2. Scene length = time to the next line. Make scene backgrounds cross-fade ~0.3 s at each boundary.
3. Inside a scene, make each element **appear about when its words are spoken**: delay ≈ `word_index / 2.6 − 0.2 s`.
4. Snappy motion: ~0.4 s ease-out rise + fade per element; 0.2 s fade-out at the end of a scene.
5. Big, short on-screen text that **supports** the voice (keywords, numbers), not a transcript.

## Recipe A: native Swift template (no dependencies, fast)

`examples/tuelang-a1/render.swift` renders a branded 9:16 promo with a generated music bed, using only macOS frameworks.

```bash
mkdir -p videos/<slug> && cp examples/tuelang-a1/render.swift videos/<slug>/
# edit the `scenes` array: start/end from the script, texts, delays, colours from tuelang-brand
swiftc -O -swift-version 5 videos/<slug>/render.swift -o /tmp/render
mkdir -p /tmp/<slug>-preview
/tmp/render videos/<slug> /tmp/<slug>-preview video.mp4   # writes videos/<slug>/video.mp4 + one preview PNG per scene
```

- Renders a ~45 s video in seconds. The second argument writes a PNG of the end of each scene: **look at them** (Read the PNGs) before handing the video over.
- Helpers in the file: `text`, `pill`, `bubble`, `check`, `roundRect`, `wordmark`, `el(t, delay) { … }`.

## Recipe B: HyperFrames (richer motion, HTML + GSAP)

The repo enables the official **hyperframes** plugin (`.claude/settings.json`), and ships **/brag** (built on HyperFrames). Use HyperFrames for motion-graphics heavy pieces: kinetic type, captions, overlays, transitions. Follow the HyperFrames skill for the CLI. Apply this spec: 1080×1920, 30 fps, safe band, scene times from the script, brand fonts from Google Fonts (Plus Jakarta Sans, DM Sans, Fraunces).

`/brag` turns a **website codebase** into a launch video. Use it when you have the Tuelang website's code checked out; it is not meant for scripted voice-over pieces.

## Recipe C: Remotion (optional)

`./setup.sh --with-remotion` installs Remotion's official agent skills. Remotion needs a company licence for teams with more than 3 people; check remotion.dev/license.

## Check before handing over

- [ ] Look at one frame per scene (preview PNGs, or `videofilmer_take_frame` on the MP4).
- [ ] Load it in VideoFilmer and `videofilmer_snapshot` in **each layout** you plan to use. Nothing important is cropped or covered.
- [ ] Scene changes land on the script's line starts (`videofilmer_status` → `script.lines`).
