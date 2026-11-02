# VideoFilmer: Tuelang's video studio

This repo is a complete kit for making **Tuelang** short videos (tuelang.com, small-group live German courses):

1. **VideoFilmer**, a native macOS app (SwiftUI + AVFoundation). The presenter reads a teleprompter while their camera and a background video are composited (camera top/bottom, corner bubble, side by side, or voice-over only) into one MP4. Takes can be reviewed, re-recorded, and their voice/video audio levels changed afterwards.
2. An **MCP server** (`mcp/`) so Claude can operate the app: load videos/scripts, change layout, record, review, see frames.
3. **Skills** (`.claude/skills/`) that define how Tuelang videos, scripts and branding must look.

## Start here

| Task | Skill |
|---|---|
| "Make a video / reel / TikTok about …" | `tuelang-video` (the whole workflow) |
| Write or fix a script, or its pace | `video-script-format` |
| Build or fix the background video | `video-format` |
| Anything Tuelang-branded | `tuelang-brand` |
| Operate the app (film, review, audio) | `videofilmer` |
| Website launch video from a codebase | `brag` / `brag-slim` (HyperFrames) |

Setup on a new Mac: `./setup.sh`, then see `docs/MCP-SETUP.md`.

## Rules

- **Check facts on the live website** (dates, prices, seats) before putting them in a script. `tuelang-brand` lists the facts as of Nov 2026.
- **Recording films the user.** Only record when asked; discard your own test takes.
- Look at what you make: preview PNGs, `videofilmer_snapshot`, `videofilmer_take_frame`.
- New videos go in `videos/<slug>/` (script.txt, render source, video.mp4, notes.md).

## Repo map

```
Sources/VideoFilmer/   the app (Swift package, macOS 14+)
  RecorderEngine.swift   capture, 30 fps compositing, MP4 writer
  Compositor.swift       layouts (Core Image)
  Script.swift           script parsing, timing, pace, speech matching
  Prompter.swift         teleprompter highlight (video time / voice / speed)
  PaceTimeline.swift     per-line pace timeline + line editor
  TakeAudio.swift        voice/video-sound mixing, re-mixable takes
  ReviewView.swift       playback + save / retake / discard
  ControlServer.swift, RemoteControl.swift   local HTTP API used by the MCP server
  CameraGuideView.swift  iPhone / camera setup guide
mcp/videofilmer-mcp.mjs  MCP server (Node, no dependencies)
examples/tuelang-a1/     reference: script.txt, render.swift (video template), the MP4
.claude/skills/          project skills (see table above)
docs/                    MCP setup, third-party credits
build.sh / setup.sh      build the .app / first-time setup
```

## Developing the app

- Build: `./build.sh` → `build/VideoFilmer.app` (ad-hoc signed with a stable identity so camera/mic permissions survive rebuilds). Debug compile: `swift build`.
- Swift 5 language mode, macOS 14 APIs. No Xcode project: SwiftPM + `build.sh` bundles `Support/Info.plist`.
- After changing the app, rebuild, relaunch, and verify via the MCP tools (`videofilmer_status`, `videofilmer_snapshot`).
- SwiftUI's `VideoPlayer` crashes in SwiftPM-built apps; use `PlayerView` (AppKit `AVPlayerView`).
