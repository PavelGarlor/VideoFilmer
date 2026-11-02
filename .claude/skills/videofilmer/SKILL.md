---
name: videofilmer
description: Operate the VideoFilmer macOS app (load a background video and a teleprompter script, pick the layout and camera/mic, rehearse, record takes, review them, set voice/video audio levels, save) through its videofilmer_* MCP tools or its local HTTP API. Use whenever the user wants to film, record, set up the teleprompter, check how a take looks, or change a take's audio.
---

# Using VideoFilmer

VideoFilmer is the native Mac app in this repo. The presenter reads a teleprompter while their camera and an AI-made background video are composited into one MP4 (9:16, 16:9 or 1:1).

## 0. Make sure it runs

- The app must be built: `build/VideoFilmer.app`. If it's missing, run `./setup.sh` (or `./build.sh`).
- The MCP server (`mcp/videofilmer-mcp.mjs`, registered in `.mcp.json`) starts the app when a tool is called. If the `videofilmer_*` tools aren't available, read `docs/MCP-SETUP.md`, or use the HTTP fallback at the bottom of this file.
- First launch: macOS asks for camera, mic (and later speech-recognition) access. Tell the user to click **Allow**; until then `cameraLive` stays `false`.

## 1. Look before acting

`videofilmer_status` returns `phase` (`idle`, `countdown`, `rehearsing`, `recording`, `saving`, `reviewing`), the loaded video, script lines with their **start/end/wpm**, the layout, the take under review, saved takes, devices, `cameraLive` and `micLevelDb`. Most changes require `phase: idle` (otherwise you get a 409).

## 2. Set up a shoot

1. `videofilmer_load_video { path }`: absolute path to the MP4.
2. `videofilmer_set_script { path }` (or `{ text }`): format in the `video-script-format` skill.
3. `videofilmer_update_settings { settings: { … } }`: only the keys to change:

| Key | Values |
|---|---|
| `layout` | `camTop` (me top, video bottom) · `videoTop` · `pip` (me in a corner) · `side` · `voiceOnly` (no camera) · `camOnly` |
| `aspect` | `vertical` (1080×1920) · `horizontal` · `square` |
| `split` | 0.25–0.75, the camera's share in split layouts |
| `corner`, `pipShape`, `pipSize` | `topRight`… · `circle` / `square` / `tall` · 0.2–0.6 |
| `fitWholeVideo` | `true` = whole video with blurred bars instead of cropping |
| `mirrorCamera` | mirror the camera image |
| `promptMode` | `video` (highlight follows video time; recommended with a timed script) · `voice` (speech recognition) · `speed` (`wpm`) |
| `language` | speech-recognition language for `voice`, e.g. `en-US`, `es-ES` |
| `fontSize`, `prompterHeight` | teleprompter text size (22–80), height share (0.2–0.75) |
| `cameraID`, `micID` | ids from `status.devices` (USB cameras, iPhone = kind `iPhone`, camera mics) |
| `includeVideoAudio`, `videoVolume` | background video's sound in new takes and its starting level (0–1) |
| `countdown` | 0, 3, 5 seconds |
| `saveCameraSeparately` | also write the clean camera (no layout, camera resolution, mic audio, same start and length as the take) for editing in another editor; saved to `~/Movies/VideoFilmer/Camera/<take> (camera).mp4`, path in `review.cameraPath` |
| `restartVideo`, `stopOnVideoEnd` | start each take at 0:00; stop when the video ends |

4. `videofilmer_snapshot`: **look at the image** to check the framing in this layout.
5. Pace: each `script.lines[]` entry has `wpm`. Fix lines outside 110–170 with `videofilmer_edit_line { line, text?, start_seconds? }`.

## 3. Recording

**Recording films the user. Only record when they ask you to.** Usually the user records themselves (⌘R in the app); you set things up and review afterwards.

- `videofilmer_rehearse { duration_seconds? }` runs video + teleprompter without recording.
- `videofilmer_record { duration_seconds }` records, stops after that long, and returns when the take is in review. Without a duration, call `videofilmer_stop`.
- If you record a test take yourself, **discard it** afterwards.

## 4. Review and audio

After a take, `phase` is `reviewing`, and `review` has the pending file, `voiceVolume`, `videoVolume`.

- `videofilmer_take_frame { path, time_seconds }` shows a frame. Check a few moments.
- `videofilmer_set_take_audio { voice_volume, video_volume }`: 0–1 each, heard live in the app.
- `videofilmer_review { action }`: `save` (mixes into `~/Movies/VideoFilmer/Take ….mp4`), `retake`, `discard`; for a saved take opened with `videofilmer_open_take`: `save` (re-mix) or `close`.
- Saved takes keep their raw recording and levels in `~/Movies/VideoFilmer/.edit/`, so audio can be re-balanced any time.

## Gotchas

- Right after launch the camera needs ~1–2 s; `record` waits up to 5 s for it.
- Takes recorded before the audio-levels feature can't be re-balanced (no `.edit` data).
- A rebuild keeps permissions (stable signing). Changing the bundle id would trigger the prompts again.
- If the window is full-screen on another Space, screen-clicking tools can't reach it. Use these tools instead.

## HTTP fallback (no MCP)

Local only: `http://127.0.0.1:47801`, header `X-VideoFilmer-Token: <token>` from `~/Library/Application Support/VideoFilmer/control.json`.

```bash
T=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Application Support/VideoFilmer/control.json')))['token'])")
curl -s -H "X-VideoFilmer-Token: $T" http://127.0.0.1:47801/status
curl -s -X POST -H "X-VideoFilmer-Token: $T" -d '{"layout":"pip"}' http://127.0.0.1:47801/settings
```

Routes: `GET /status`, `GET|POST /settings`, `POST /video {path}`, `POST /script {text|path}`, `POST /script/line {line,text?,start?}`, `POST /record|/rehearse {duration?}`, `POST /stop`, `POST /review {action}`, `POST /review/mix {voiceVolume,videoVolume}`, `POST /takes/open {path}`, `POST /jump {word}`, `POST /guide {tab}`, `GET /snapshot` (PNG), `GET /frame?path=&t=` (PNG).
