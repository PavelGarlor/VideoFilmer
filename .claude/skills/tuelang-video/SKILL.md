---
name: tuelang-video
description: End-to-end workflow for making a Tuelang video, from a page or brief to a timed script, a branded background video, setup in VideoFilmer, recording, review and social captions. Use when asked to "make a video", "create a reel/short/TikTok", or "a video about <Tuelang page or course>".
---

# Making a Tuelang video

Follow these steps in order. Each step names the skill with the details.

## 1. Brief (ask only what you can't infer)

- **Topic / page**: e.g. the A1 cohort page. **Read the live page** (WebFetch or the browser) for current facts. Don't rely on memory or old scripts.
- **Platform and format**: Reels/TikTok/Shorts → vertical 9:16 (default); YouTube → 16:9.
- **Presenter layout**: me top/video bottom (`camTop`, default for talking-head promos), me in a top-right circle (`pip`), or voice-over only.
- **Length**: 30–50 s unless told otherwise. **Language**: English unless told otherwise.

## 2. Script → `videos/<slug>/script.txt`

Use `video-script-format` + `tuelang-brand`. Hook → what → how → why → outcome → offer → CTA. Every line timed, 110–170 wpm (aim 140–165), numbers written as spoken. Show the script to the user before rendering if they asked to review it.

## 3. Background video → `videos/<slug>/video.mp4`

Use `video-format` + `tuelang-brand`.

- Default: copy `examples/tuelang-a1/render.swift` to `videos/<slug>/`, rewrite the `scenes` to the new script (one scene per line, start/end from the script times), render, and **look at the preview PNGs**.
- Richer motion: HyperFrames (plugin enabled in this repo) with the same spec. `/brag` is for website launch videos made from a codebase.
- Keep everything important in the safe band (y 480–1440) for split layouts; keep the top-right corner clear for `pip`.

## 4. Set up VideoFilmer

Use `videofilmer`: `load_video` → `set_script` → `update_settings` (layout, aspect, `promptMode: video`) → `snapshot` and look at it → check `script.lines` paces.

## 5. Record (the user does this)

Tell the user it's ready: press **⌘R** (or **Rehearse** first). Only record yourself if asked. After a take, help review: frames, `set_take_audio` (voice 100%, video sound 20–35% is a good start), `save` or `retake`.

## 6. Deliver

- Final file: the saved take in `~/Movies/VideoFilmer/`.
- Write `videos/<slug>/notes.md` with a post caption (1–2 lines, brand voice, one CTA), 3–6 hashtags (#learngerman #deutschlernen #germanforbeginners …), and the facts you used with the date you checked them.
- Commit `videos/<slug>/` (script, render source, video, notes) if the user wants it in the repo.

## Example

`examples/tuelang-a1/` holds the A1 founding cohort promo: `script.txt`, `render.swift`, `tuelang-a1-cohort.mp4` (42 s, 9:16).
