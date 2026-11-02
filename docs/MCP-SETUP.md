# Setting up VideoFilmer for Claude

Claude drives the VideoFilmer app through an **MCP server** (`mcp/videofilmer-mcp.mjs`). The server talks to the running app over a local, token-protected HTTP API. Nothing leaves your Mac.

```
Claude Code ──(MCP, stdio)──> mcp/videofilmer-mcp.mjs ──(HTTP 127.0.0.1:47801 + token)──> VideoFilmer.app
```

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode or the Command Line Tools (for `swift`)
- Node.js 18+ (for the MCP server; it has no npm dependencies)
- Claude Code

## 1. Build the app

```bash
./setup.sh
```

This checks the tools and builds `build/VideoFilmer.app`. Open it once (`open build/VideoFilmer.app`) and click **Allow** for the camera and microphone. The app is signed ad hoc with a stable identity, so rebuilding doesn't ask again.

## 2. Connect Claude Code

The repo's `.mcp.json` registers the server; it finds the repo root itself, so no paths need editing:

```json
{ "mcpServers": { "videofilmer": { "command": "sh", "args": ["-c", "cd \"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\" && exec node mcp/videofilmer-mcp.mjs"] } } }
```

Start Claude Code in the repo folder and approve the **videofilmer** server when asked (or run `/mcp`).

### Recommended project settings

Create `.claude/settings.json` with this so the server is trusted, its tools don't prompt each time, and the HyperFrames video skills are enabled:

```json
{
  "enabledMcpjsonServers": ["videofilmer"],
  "permissions": { "allow": ["mcp__videofilmer"] },
  "enabledPlugins": { "hyperframes@claude-plugins-official": true }
}
```

## 3. Check it works

Ask Claude: *"What's the VideoFilmer status?"* It should call `videofilmer_status` (and open the app if it was closed). Then try *"take a snapshot"*: you'll get an image of the current composite.

## Tools

| Tool | What it does |
|---|---|
| `videofilmer_status` | Phase, video, script lines with pace, layout, review, takes, devices |
| `videofilmer_load_video` | Load the background video |
| `videofilmer_set_script` | Set the teleprompter script (text or file) |
| `videofilmer_edit_line` | Change one line's text and/or start time |
| `videofilmer_get_settings` / `videofilmer_update_settings` | Read / change layout, format, devices, teleprompter, audio… |
| `videofilmer_rehearse` / `videofilmer_record` / `videofilmer_stop` | Run a take (optionally for N seconds) |
| `videofilmer_set_take_audio` | Voice and video sound levels of the take under review |
| `videofilmer_review` | `save`, `retake`, `discard`, `close` |
| `videofilmer_open_take` | Open a saved take to watch or re-mix it |
| `videofilmer_snapshot` | Image of the live composite |
| `videofilmer_take_frame` | Image of a frame of any recorded file |
| `videofilmer_jump` | Move the teleprompter highlight |

## Other MCP clients (Claude Desktop, etc.)

Use an absolute path:

```json
{ "mcpServers": { "videofilmer": { "command": "node", "args": ["/ABSOLUTE/PATH/TO/VideoFilmer/mcp/videofilmer-mcp.mjs"] } } }
```

## Troubleshooting

| Problem | Fix |
|---|---|
| "VideoFilmer isn't running and didn't start" | Build it: `./setup.sh`. The server opens `build/VideoFilmer.app`. |
| `cameraLive: false` | Allow camera access (System Settings › Privacy & Security › Camera), or pick another camera. |
| 401 "wrong token" | The token lives in `~/Library/Application Support/VideoFilmer/control.json`; quit and reopen the app. |
| Port 47801 busy | Another copy of the app is running. Quit it. |
| 409 "busy" | Stop the take or finish the review first (`videofilmer_stop`, `videofilmer_review`). |
| Tools missing in Claude Code | Run `/mcp`, check "videofilmer" is approved and connected; restart Claude Code in the repo folder. |
| iPhone camera not listed | In the app: Help › Use Your iPhone as a Camera…, a guided checklist. |
