# Using another music model in Standard Music

Standard Music records every song on your Mac. By default it uses the bundled YuE2 engine, but
the model is replaceable: everything else (artists, albums, lyrics, taste, the player, sharing)
stays the same, and only the recording step changes.

To use another model, you write a small program called an **engine**. Standard Music launches it,
sends it songs to record, and plays what it writes. Then you point the app at it in
**Settings › Studio › Music engine › Your own engine**.

A complete, working example lives at `tools/engines/minimax_engine.py`. It runs MiniMax Music 3
on MLX in about 200 lines. The quickest path is to copy it and replace `render()` with your model.

## The protocol

The engine is any executable: a Python script with a `#!` line, a compiled binary, or a shell
script that forwards to a server. Standard Music talks to it over **stdin** and **stdout**, one
JSON object per line, UTF-8, each terminated by `\n`.

- **stdout** is reserved for protocol messages. Print logs, warnings and progress bars to
  **stderr**. If a library you use prints to stdout, redirect it, as the example does with `dup2`.
- **stderr** is kept. If the engine exits unexpectedly, its last stderr line is shown to the
  listener, so a Python traceback ends with something readable.
- One song is recorded at a time. Standard Music sends the next `generate` only after the
  previous song finished, failed or was cancelled.
- The engine can stay running between songs and keep its model in memory. Standard Music closes
  stdin (or sends `shutdown`) after the studio has been idle for the time set under
  **Unload the model after**. Exit promptly when either happens.

### Messages Standard Music sends

`load` comes first, and again whenever the Model setting changes:

```json
{"load":{"modelPath":"mlx-community/MiniMax-Music3-mxfp8"}}
```

`modelPath` is whatever the listener typed into **Model**. If that field is empty, it is the
folder the engine program lives in. Load the model, then reply with `ready`.

`generate` records one song:

```json
{"generate":{"_0":{
  "id": "4f1c…",
  "style": "English, indie rock, driving, crunchy electric guitars, female vocal, powerful, warm alto",
  "lyrics": "[Intro]\n\n[Verse]\nHeadlights on the county road,\n…\n[Chorus]\nSo turn it up…",
  "planning": "full",
  "seed": 1216756351,
  "steps": 16,
  "maxSemanticTokens": 8250,
  "outputPath": "/Users/you/Library/Application Support/StandardMusic/Library/Audio/4f1c….m4a",
  "title": "Turn It Up",
  "artist": "The Halts",
  "voice": "female vocal, powerful, warm alto, slightly husky",
  "isInstrumental": false,
  "maxSeconds": 330
}}}
```

| Field | Meaning |
|---|---|
| `id` | Echo it back in every reply about this song. |
| `style` | Comma-separated tags: language, genre, era, instruments, mood, then the artist's voice. This is the main prompt. |
| `lyrics` | Full lyrics with section tags (`[Verse]`, `[Chorus]`, `[Bridge]`, `[Interlude]`, `[Outro]`…). Empty sections mean instrumental passages. |
| `seed` | Use it. The same song should come out the same every time, including on a friend's Mac after a shared album. |
| `steps` | The listener's quality setting: 8 (Demo), 16 (Balanced) or 32 (Studio). Map it onto your model's own speed/quality knob. |
| `planning`, `maxSemanticTokens` | YuE2-specific. Ignore them unless your model has an equivalent. |
| `title`, `artist`, `voice`, `isInstrumental` | The same information broken out, for models that take it separately. `voice` is already included in `style`. |
| `maxSeconds` | The longest song the listener wants. Stop, or fade out, by then. |
| `outputPath` | Where to write the recording. |

`cancel` arrives on stdin **while a song is rendering**, so read stdin on a separate thread:

```json
{"cancel":{"id":"4f1c…"}}
```

Stop as soon as you reasonably can, and reply with `cancelled`. If your model can't be
interrupted, finish the song and reply with `cancelled` instead of `finished`.

`shutdown` means exit now:

```json
{"shutdown":{}}
```

### Messages the engine sends

`ready`, after `load`:

```json
{"ready":{"loadSeconds":4.2}}
```

`progress`, as often as you like (a few times a second is plenty). The `_1` key is not a typo; it
is how the app's Swift side encodes an unnamed value:

```json
{"progress":{"id":"4f1c…","_1":{"stage":"rendering","stageFraction":0.4,"overall":0.55,"elapsed":31.2,"estimatedSongSeconds":184}}}
```

- `stage`: one of `loading`, `planning`, `composing`, `rendering`, `mastering`, `encoding`. It
  picks the words the app shows.
- `stageFraction` and `overall` run from 0 to 1. `overall` drives the progress bar.
- `elapsed` is in seconds. `estimatedSongSeconds` (optional) is the song's expected length.

**Send something at least every few minutes.** Standard Music restarts an engine that has said
nothing for ten minutes in the middle of a song, on the assumption that it hung. If your model
gives no progress callbacks, send estimated progress from a timer thread, as the example does.

`finished`, after the file is completely written:

```json
{"finished":{"_0":{"id":"4f1c…","duration":182.4,"loudness":-14.2,"seconds":95.0,"truncated":false}}}
```

| Field | Meaning |
|---|---|
| `duration` | Length of the written song, in seconds. |
| `loudness` | Integrated loudness, roughly LUFS. Sound Check uses it to even out volume. The example's `loudness()` matches the built-in engine. |
| `seconds` | How long recording took. The app uses it for time estimates. |
| `truncated` | `true` if the song hit `maxSeconds` and was cut (it should fade out). |
| `abc` | Optional: a symbolic score, if your model makes one. |

`failed`, if a song can't be recorded. Leave out `id` if the failure isn't about a song (for
example, a failed `load`):

```json
{"failed":{"id":"4f1c…","message":"Out of memory while decoding."}}
```

`cancelled`, after a `cancel`:

```json
{"cancelled":{"id":"4f1c…"}}
```

### The audio file

- Write **AAC in an .m4a container** to `outputPath`. 44.1 or 48 kHz stereo at 256 kbps is ideal.
  On a Mac, `afconvert -f m4af -d aac -b 256000 in.wav out.m4a` does it.
- Write to a temporary file next to `outputPath` and rename it into place, so a crash never
  leaves a half-written song where the app expects a finished one.
- Trim leading silence. Fade out if you cut the song short.

## Setting it up in the app

1. Open **Settings › Studio** and set **Music engine** to **Your own engine**.
2. **Program**: choose your executable. Scripts need a `#!` line and `chmod +x`.
3. **Arguments** (optional): passed when the engine launches, split like a shell would
   (`--python ~/venvs/mm/bin/python --quant 8bit`).
4. **Model** (optional): sent in `load`. Use a folder, a Hugging Face id, or anything your engine understands.
5. Press **Test Engine**. Standard Music launches the program, sends `load`, and waits for
   `ready`. If it fails, the error and the engine's last stderr line are shown.

Your quality, record-ahead, background-recording and unload settings all still apply.

## Things worth knowing

- **Existing recordings don't change.** Only songs recorded from now on use the new engine.
  To hear an old song through the new model, delete its recording and play it again.
- **Shared albums say which engine recorded them.** When a friend imports an album you shared,
  any songs that weren't included are recorded on *their* Mac with *their* engine. The import
  sheet warns them if that's different from yours.
- **Engines run with your permissions**, like any program you install. Only use code you trust.
- **Check the model's license.** YuE2 is CC BY-NC 4.0 (non-commercial). MiniMax Music 3 has its
  own community license. What you may do with the songs depends on the model that made them.

## Testing an engine without the app

You can drive an engine by hand. Generate the commands with a JSON tool, because lyrics contain
newlines that must be escaped:

```sh
python3 -c 'import json
print(json.dumps({"load":{"modelPath":""}}))
print(json.dumps({"generate":{"_0":{"id":"t1","style":"indie rock, female vocal","lyrics":"[verse]\nHello\n[chorus]\nTurn it up","planning":"full","seed":7,"steps":8,"outputPath":"/tmp/t1.m4a","maxSeconds":20}}}))' \
| ./my_engine.py
```

You should see `ready`, some `progress`, then `finished`, with nothing else on stdout. Then play
`/tmp/t1.m4a`.
