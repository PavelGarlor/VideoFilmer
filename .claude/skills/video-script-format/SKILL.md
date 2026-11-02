---
name: video-script-format
description: How to write a voice-over script for VideoFilmer's teleprompter, covering the file format ([m:ss] timings, notes, labels), speaking pace (words per minute per line) and structure for short promo videos. Use when writing, timing, fixing or reviewing a script that someone will read on camera over a video.
---

# Writing a VideoFilmer script

A script is a plain `.txt` file. The teleprompter highlights each word as it is due, so **the timing in the script is the timing of the video**. Write the script first, then build the video from its timings (see the `video-format` skill).

## File format

```text
[0:00] Want to order coffee in Berlin by February?
[0:03.5] Tuelang's A1 German cohort starts January twelfth, and you start from zero.
[0:08.5] Eight weeks of live classes, twice a week, with only ten students.
(smile) [B-roll: classroom] HOOK: These are shown small and are not read.
```

- **One spoken line per row.** A row becomes a block on VideoFilmer's Pace timeline and a paragraph in the teleprompter.
- **`[m:ss]` or `[m:ss.s]` at the start of a row** pins that line to that moment of the video. Also accepted: `0:12 -`, `(0:12)`, `[0:12 - 0:18]` (the start is used). Put a time on **every** line. The app spreads words between times, so untimed lines drift.
- `[notes]` and `(notes)` anywhere are stage directions: shown small, never read, never matched.
- `HOOK:`, `VO:`, `NARRATOR:` (capitals + colon at the start) are labels: shown small, not read.
- Leading `-`, `*`, `•`, `#` bullets are stripped. Blank rows are ignored. `*bold*` asterisks are removed.

## Pace

Measure each line: `words ÷ seconds × 60` = words per minute (wpm). VideoFilmer shows this per line (status `script.lines[].wpm`, the Pace timeline colours).

| wpm | Feels | Colour in the app |
|---|---|---|
| < 110 | slow, dragging | blue |
| **110–170** | **comfortable; aim for 140–165** | green |
| 170–195 | fast, rushed | orange |
| > 195 | too fast to say clearly | red |

Rules of thumb:

- Line duration ≈ `words / 2.6 + 0.4 s` (2.6 words/s ≈ 155 wpm, plus a breath).
- Keep lines **≤ 20 words**. Split long sentences into two timed lines.
- The **first line is the hook**: ≤ 10 words, ≤ 3.5 s.
- The last line is the CTA. Give it ~1 s extra at the end so the video doesn't cut on the last word.
- Numbers and symbols are written **as they're said**: "three hundred ninety-nine euros", "January twelfth", "tuelang dot com". This reads naturally and lets "follow my voice" mode match the words.
- Avoid tongue-twisters and stacked clauses; read every line aloud once.

## Structure for a 30–60 s promo

1. **Hook** (0–4 s): a question or a vivid outcome ("order coffee in Berlin").
2. **What it is** (1 line): name, start date, from zero.
3. **How it works** (1–2 lines): concrete format details.
4. **Why it works** (1–2 lines): one differentiator, said simply.
5. **The outcome** (1 line): what you'll be able to do.
6. **Offer / extra** (1 line): price, refund, Berlin trip.
7. **CTA** (1 line): one action, one URL.

Aim for 6–9 lines and 35–50 s total for Reels, TikTok and Shorts.

## Checklist before handing it over

- [ ] Every line has a `[m:ss(.s)]` start, increasing, and fits inside the video length.
- [ ] Every line is 110–170 wpm (green); fix orange/red lines by cutting words or giving them more time.
- [ ] Numbers and URLs are written as spoken.
- [ ] Facts match the live website (see `tuelang-brand`).
- [ ] Load it into VideoFilmer (`videofilmer_set_script`) and check `script.lines` in `videofilmer_status`.

Reference: `examples/tuelang-a1/script.txt`.
