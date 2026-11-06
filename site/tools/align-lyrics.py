"""Times each lyric line inside the site's preview clips, so Now Playing highlights the line being sung.

  python tools/align-lyrics.py public/data/library.json

Needs mlx-whisper (pip install mlx-whisper) and macOS's afconvert. For every track with a clip and lyrics it
transcribes the clip with word timestamps, aligns the words to the lyrics and writes `cues` on the track: one
entry per lyric line (section headers and blank lines excluded), the second in the clip where that line starts,
or null when the line isn't heard in the clip. Run it after tools/export-library.mjs.
"""
import json
import re
import subprocess
import sys
import tempfile
import wave
from difflib import SequenceMatcher
from pathlib import Path

import mlx_whisper
import numpy as np

MODEL = "mlx-community/whisper-large-v3-turbo"


def norm(word):
    return re.sub(r"[^a-z0-9']", "", word.lower())


def lines_of(lyrics):
    return [l for l in lyrics.split("\n") if l.strip() and not re.match(r"^\[.+\]$", l.strip())]


def transcribe(clip):
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "clip.wav"
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(clip), str(wav)], check=True)
        w = wave.open(str(wav))
        audio = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
    result = mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, word_timestamps=True, language="en")
    return [(wd["start"], norm(wd["word"])) for s in result["segments"] for wd in s.get("words", []) if norm(wd["word"])]


def align(words, lines, expected_start):
    """Semi-global alignment of the heard words to the lyric words. Choruses repeat, so ties go to the copy
    nearest where the clip sits in the song (`expected_start`, 0…1 through the lyrics)."""
    lyric = [(k, norm(w)) for k, line in enumerate(lines) for w in line.split() if norm(w)]
    n, m = len(words), len(lyric)
    if not n or not m:
        return [None] * len(lines)
    expect = lambda i: expected_start * m + i  # heard word i is about lyric word expect(i)

    def score(i, j):
        a, b = words[i][1], lyric[j][1]
        same = a == b or SequenceMatcher(None, a, b).ratio() >= 0.8
        return (2 if same else -1) - 0.005 * abs(j - expect(i))

    NEG = float("-inf")
    best = [[0.0] * (m + 1)] + [[NEG] * (m + 1) for _ in range(n)]  # leading lyric gaps are free
    move = [[None] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        for j in range(0, m + 1):
            options = [(best[i - 1][j] - 1, "skip-heard")]
            if j:
                options += [(best[i - 1][j - 1] + score(i - 1, j - 1), "pair"), (best[i][j - 1] - 1, "skip-lyric")]
            best[i][j], move[i][j] = max(options)
    i, j = n, max(range(m + 1), key=lambda c: best[n][c])  # trailing lyric gaps are free
    first = {}
    hits = {}
    while i > 0:
        step = move[i][j]
        if step == "pair":
            k = lyric[j - 1][0]
            if words[i - 1][1] == lyric[j - 1][1] or SequenceMatcher(None, words[i - 1][1], lyric[j - 1][1]).ratio() >= 0.8:
                first[k] = min(first.get(k, 1e9), words[i - 1][0])
                hits[k] = hits.get(k, 0) + 1
            i, j = i - 1, j - 1
        elif step == "skip-heard":
            i -= 1
        else:
            j -= 1
    cues = []
    for k, line in enumerate(lines):
        size = len([w for w in line.split() if norm(w)])
        ok = hits.get(k, 0) >= max(1, round(size * 0.3))
        cues.append(round(first[k], 2) if ok else None)
    # A line can only start after the one before it.
    last = -1e9
    for k, c in enumerate(cues):
        if c is not None and c < last:
            cues[k] = None
        elif c is not None:
            last = c
    return cues


def main(path):
    path = Path(path)
    data = json.loads(path.read_text())
    root = path.parent.parent
    for album in data["albums"]:
        for t in album["tracks"]:
            if not (t.get("clip") and t.get("lyrics")):
                continue
            lines = lines_of(t["lyrics"])
            start = t.get("clipStart")
            if start is None:  # tools/export-library.mjs cuts from 32% in (at least 20 s)
                start = max(20, (t.get("duration") or 180) * 0.32)
            where = start / max(1, t.get("duration") or 180)
            t["cues"] = align(transcribe(root / t["clip"]), lines, where)
            heard = sum(c is not None for c in t["cues"])
            print(f"{t['title']}: {heard}/{len(lines)} lines timed", file=sys.stderr)
    path.write_text(json.dumps(data, separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1])
