# VideoFilmer: Tuelang video studio

A kit for making **Tuelang** short videos with Claude:

- **VideoFilmer**, a native macOS app for filming yourself over a background video, with a teleprompter that highlights the script as you speak. Layouts: camera top/bottom, round or square corner bubble, side by side, voice-over only.
- **MCP server**, so Claude Code can run the app for you: load videos and scripts, set layouts, record, review, adjust audio.
- **Skills** in `.claude/skills/` that teach Claude the Tuelang workflow, script format and pacing, video specs, and the Tuelang brand. Also included: **brag** / **brag-slim** for launch videos, with **HyperFrames** recommended as a plugin.

## Quick start

```bash
git clone <this repo> && cd VideoFilmer
./setup.sh                 # checks tools, builds build/VideoFilmer.app
open build/VideoFilmer.app # allow camera + microphone
claude                     # approve the "videofilmer" MCP server
```

Then ask Claude: *"Make a Tuelang video about the A1 cohort"*. Setup details: [docs/MCP-SETUP.md](docs/MCP-SETUP.md). Guide for Claude: [CLAUDE.md](CLAUDE.md). Credits: [docs/THIRD-PARTY.md](docs/THIRD-PARTY.md).

Needs macOS 14+, Xcode (or the Command Line Tools) and Node 18+. The first launch asks for camera, microphone and (for voice follow) speech recognition access. Rebuilds keep those permissions.

## How it works

1. **Sources**: load the AI video (button or drag it onto the preview) and paste the script.
2. **Layout**: vertical, horizontal or square output; me top/video bottom, video top/me bottom, me in a corner (rounded or circle), side by side, voice-over only, or only me.
3. **Teleprompter**: the highlight can follow
   - **the video timing**: the script is spread over the video. Start a line with `[0:12]` to pin it to that moment.
   - **my voice**: Apple speech recognition (on-device when available) moves the highlight as you read.
   - **a fixed speed** in words per minute.

   Click any word to jump there. `[notes]`, `(notes)` and `SPEAKER:` labels are shown small and skipped.

   **Editing:** double-click a line in the teleprompter to change its text; the editor shows how fast the line will have to be read. The **Pace** timeline under the teleprompter lays each line along the video with its words per minute (green = comfortable, orange = fast, red = too fast). Drag the edges between lines to give a line more or less time, or select a line and use **Slower** / **Faster**. The new timings are written into the script as `[m:ss.s]`.
4. **Record** (⌘R) or **Rehearse** (⇧⌘R); Esc stops. Each take then plays back with two sliders, **My voice** and **Video sound** (the AI video's own audio), and you can **Save**, **Record again** or **Discard** it. Saved takes go to `~/Movies/VideoFilmer` as MP4. Their raw recording and audio levels are kept in `.edit`, so you can reopen a take later, change the balance and save it again.

Turn on **Also save my camera on its own** to get, next to each take, a clean full-frame camera file (with your mic) that lines up exactly with the take, for cutting between full-frame you and the composite in Premiere, Final Cut, DaVinci or CapCut. These files go to `~/Movies/VideoFilmer/Camera/`.

The camera and mic can be the Mac's own, a USB camera, an iPhone (Continuity Camera) or an external mic; choose them under **Camera & mic**. The **Use your iPhone as a camera…** button (also in the Help menu) opens a step-by-step guide that turns green as soon as the iPhone is found. It has a second tab for cameras like Sony or Canon. "Me in a corner" can be round, square or tall, in any corner.

## Remote control (MCP)

While it runs, the app listens on `127.0.0.1:47801` (local only). Each request needs the token stored in `~/Library/Application Support/VideoFilmer/control.json`. `mcp/videofilmer-mcp.mjs` wraps that as an MCP server, registered in `.mcp.json`, so Claude Code can:

- load a video and a script
- change any setting
- record or rehearse, optionally for a set number of seconds
- save, retake or discard a take
- see the live composite (`videofilmer_snapshot`) or any frame of a take (`videofilmer_take_frame`)

The MCP server starts the app if it isn't running.

## Code

- `RecorderEngine.swift`: camera/mic capture, AI video playback, 30 fps compositing, MP4 writing, audio mix
- `Compositor.swift`: the layouts (Core Image)
- `Script.swift`: script parsing, word timing, speech-to-script matching
- `Prompter.swift`: highlight controller + speech recognition
- `AppModel.swift`, `Views.swift`, `PrompterTextView.swift`: the UI
