#!/usr/bin/env node
// MCP server (stdio, no dependencies) that drives the VideoFilmer Mac app
// through its local control API on 127.0.0.1. Starts the app if it isn't running.

import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const APP = resolve(here, '../build/VideoFilmer.app');
const CONFIG = join(homedir(), 'Library/Application Support/VideoFilmer/control.json');

function readConfig() {
  try { return JSON.parse(readFileSync(CONFIG, 'utf8')); } catch { return null; }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Calls the app. Returns parsed JSON, or a Buffer when `binary` is set. */
async function api(method, path, body, { binary = false } = {}) {
  for (let attempt = 0; ; attempt++) {
    const cfg = readConfig();
    let res;
    try {
      if (!cfg) throw Object.assign(new Error('no config'), { unreachable: true });
      res = await fetch(`http://127.0.0.1:${cfg.port}${path}`, {
        method,
        headers: { 'X-VideoFilmer-Token': cfg.token, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (err) {
      const unreachable = err.unreachable || err.cause?.code === 'ECONNREFUSED';
      if (!unreachable) throw err;
      if (attempt >= 30) throw new Error(`VideoFilmer isn't running and didn't start (${APP}). Build it with ./build.sh.`);
      if (attempt === 0) await new Promise((r) => execFile('open', [APP], () => r()));
      await sleep(500);
      continue;
    }
    if (binary && res.ok) return Buffer.from(await res.arrayBuffer());
    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { data = { raw: text }; }
    if (!res.ok) throw new Error(data.error || text);
    return data;
  }
}

const textResult = (data) => ({ content: [{ type: 'text', text: JSON.stringify(data, null, 2) }] });
const imageResult = (png, note) => ({
  content: [
    { type: 'image', data: png.toString('base64'), mimeType: 'image/png' },
    ...(note ? [{ type: 'text', text: note }] : []),
  ],
});

const tools = [
  {
    name: 'videofilmer_status',
    description: 'Current state of the VideoFilmer app: phase (idle, countdown, rehearsing, recording, saving, reviewing), loaded video, script and teleprompter position, layout, the take under review, saved takes and devices.',
    inputSchema: { type: 'object', properties: {} },
    run: () => api('GET', '/status').then(textResult),
  },
  {
    name: 'videofilmer_load_video',
    description: 'Load the AI video to film over (absolute path to a video file on this Mac).',
    inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
    run: ({ path }) => api('POST', '/video', { path }).then(textResult),
  },
  {
    name: 'videofilmer_set_script',
    description: 'Set the teleprompter script, either as text or from a text file. A line starting with [m:ss] (or [m:ss.s]) is pinned to that moment of the video; [notes], (notes) and SPEAKER: labels are shown small and not read.',
    inputSchema: {
      type: 'object',
      properties: { text: { type: 'string' }, path: { type: 'string', description: 'Absolute path to a .txt file' } },
    },
    run: (args) => api('POST', '/script', args.text !== undefined ? { text: args.text } : { path: args.path }).then(textResult),
  },
  {
    name: 'videofilmer_edit_line',
    description: 'Edit one line of the script (index from script.lines in videofilmer_status): change its text and/or the second of the video where it starts. Each line in status shows its start, end and words per minute (comfortable ≈ 110–170). Moving a line\'s start gives the line before it more or less time.',
    inputSchema: {
      type: 'object',
      properties: { line: { type: 'integer' }, text: { type: 'string' }, start_seconds: { type: 'number' } },
      required: ['line'],
    },
    run: ({ line, text, start_seconds }) => api('POST', '/script/line', { line, text, start: start_seconds }).then(textResult),
  },
  {
    name: 'videofilmer_get_settings',
    description: 'All settings with their current values and the allowed values.',
    inputSchema: { type: 'object', properties: {} },
    run: () => api('GET', '/settings').then(textResult),
  },
  {
    name: 'videofilmer_update_settings',
    description: 'Change settings. Pass only the keys to change. Keys: layout (camTop, videoTop, pip, side, voiceOnly, camOnly), aspect (vertical, horizontal, square), split 0.25–0.75 (camera share), corner (topLeft, topRight, bottomLeft, bottomRight), pipSize 0.2–0.6, pipShape (circle, square, tall), fitWholeVideo, mirrorCamera, promptMode (video, voice, speed), wpm, language (e.g. en-US, es-ES), fontSize, prompterHeight, includeVideoAudio, videoVolume 0–1, monitorVideoAudio, restartVideo, stopOnVideoEnd, countdown (0, 3, 5), cameraID, micID.',
    inputSchema: { type: 'object', properties: { settings: { type: 'object' } }, required: ['settings'] },
    run: ({ settings }) => api('POST', '/settings', settings).then(textResult),
  },
  {
    name: 'videofilmer_record',
    description: 'Start recording a take (countdown, video and teleprompter start together). With duration_seconds it stops by itself after that long and returns once the take is ready to review; without it, call videofilmer_stop. The finished take waits in review until videofilmer_review saves or discards it.',
    inputSchema: { type: 'object', properties: { duration_seconds: { type: 'number' } } },
    run: ({ duration_seconds }) => api('POST', '/record', duration_seconds ? { duration: duration_seconds } : {}).then(textResult),
  },
  {
    name: 'videofilmer_rehearse',
    description: 'Run through the video and teleprompter without recording. Optional duration_seconds stops it after that long.',
    inputSchema: { type: 'object', properties: { duration_seconds: { type: 'number' } } },
    run: ({ duration_seconds }) => api('POST', '/rehearse', duration_seconds ? { duration: duration_seconds } : {}).then(textResult),
  },
  {
    name: 'videofilmer_stop',
    description: 'Stop the countdown, rehearsal or recording. A stopped recording goes to review.',
    inputSchema: { type: 'object', properties: {} },
    run: () => api('POST', '/stop', {}).then(textResult),
  },
  {
    name: 'videofilmer_review',
    description: 'Decide on the take being reviewed: save (fresh take: mix it into the takes folder; saved take: re-mix it with the new audio levels), retake (discard and record again), discard, or close.',
    inputSchema: { type: 'object', properties: { action: { type: 'string', enum: ['save', 'retake', 'discard', 'close'] } }, required: ['action'] },
    run: ({ action }) => api('POST', '/review', { action }).then(textResult),
  },
  {
    name: 'videofilmer_set_take_audio',
    description: 'While a take is being reviewed, set how loud the recorded voice and the AI video\'s own sound are (0–1 each). Then videofilmer_review save to write it. Works on fresh takes and on saved takes opened with videofilmer_open_take.',
    inputSchema: {
      type: 'object',
      properties: { voice_volume: { type: 'number', minimum: 0, maximum: 1 }, video_volume: { type: 'number', minimum: 0, maximum: 1 } },
    },
    run: ({ voice_volume, video_volume }) => api('POST', '/review/mix', { voiceVolume: voice_volume, videoVolume: video_volume }).then(textResult),
  },
  {
    name: 'videofilmer_open_take',
    description: 'Open a saved take (path from videofilmer_status takes) in the app to watch it or change its audio levels.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] },
    run: ({ path }) => api('POST', '/takes/open', { path }).then(textResult),
  },
  {
    name: 'videofilmer_jump',
    description: 'Move the teleprompter highlight to a word index.',
    inputSchema: { type: 'object', properties: { word: { type: 'integer' } }, required: ['word'] },
    run: ({ word }) => api('POST', '/jump', { word }).then(textResult),
  },
  {
    name: 'videofilmer_snapshot',
    description: 'Image of what the app is composing right now (camera + AI video in the current layout) — exactly what gets recorded.',
    inputSchema: { type: 'object', properties: {} },
    run: () => api('GET', '/snapshot', undefined, { binary: true }).then((png) => imageResult(png)),
  },
  {
    name: 'videofilmer_take_frame',
    description: 'Image of one frame of a recorded take (or any video file) at time_seconds, to check a recording.',
    inputSchema: { type: 'object', properties: { path: { type: 'string' }, time_seconds: { type: 'number' } }, required: ['path'] },
    run: ({ path, time_seconds = 0 }) =>
      api('GET', `/frame?path=${encodeURIComponent(path)}&t=${time_seconds}`, undefined, { binary: true })
        .then((png) => imageResult(png, `${path} at ${time_seconds}s`)),
  },
];

// MARK: - JSON-RPC over stdio

const send = (msg) => process.stdout.write(JSON.stringify(msg) + '\n');

async function handle(msg) {
  const { id, method, params } = msg;
  if (id === undefined) return; // notifications
  try {
    let result;
    switch (method) {
      case 'initialize':
        result = {
          protocolVersion: params?.protocolVersion ?? '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'videofilmer', version: '0.1.0' },
          instructions: 'Drives the VideoFilmer Mac app: load an AI video and a script, choose a layout, record takes over the video with a teleprompter, then review, save or retake them. Use videofilmer_snapshot and videofilmer_take_frame to see the result.',
        };
        break;
      case 'ping':
        result = {};
        break;
      case 'tools/list':
        result = { tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) };
        break;
      case 'tools/call': {
        const tool = tools.find((t) => t.name === params?.name);
        if (!tool) throw Object.assign(new Error(`Unknown tool ${params?.name}`), { rpc: -32602 });
        try {
          result = await tool.run(params.arguments ?? {});
        } catch (err) {
          result = { content: [{ type: 'text', text: String(err.message ?? err) }], isError: true };
        }
        break;
      }
      default:
        throw Object.assign(new Error(`Method not found: ${method}`), { rpc: -32601 });
    }
    send({ jsonrpc: '2.0', id, result });
  } catch (err) {
    send({ jsonrpc: '2.0', id, error: { code: err.rpc ?? -32603, message: String(err.message ?? err) } });
  }
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  handle(msg);
});
