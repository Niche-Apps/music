#!/usr/bin/env python3
"""A Standard Music engine for MiniMax Music 3 on Apple Silicon (MLX).

This is the reference example for docs/custom-engines.md: copy it and swap `render()` for your
own model. It speaks the engine protocol — one JSON object per line on stdin and stdout.

Setup (once):
    uv venv ~/.standardmusic-minimax && \
      uv pip install --python ~/.standardmusic-minimax/bin/python numpy soundfile \
      "mlx-audio @ git+https://github.com/Blaizzy/mlx-audio.git@784b29e2691a93ca7483147d86f61859dfaa6296"

Then in Standard Music › Settings › Studio › Your own engine:
    Program:   /path/to/minimax_engine.py
    Arguments: --python ~/.standardmusic-minimax/bin/python     (or point the #! line at that venv)
    Model:     mlx-community/MiniMax-Music3-mxfp8                (or a local folder)

MiniMax Music 3 weights are under the MiniMax-Music3 Community License. Read it before you
share what you make.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time

DEFAULT_MODEL = "mlx-community/MiniMax-Music3-mxfp8"

# Re-run under the interpreter given with --python, so the #! line can stay generic.
if "--python" in sys.argv:
    i = sys.argv.index("--python")
    python = os.path.expanduser(sys.argv[i + 1])
    if os.path.realpath(sys.executable) != os.path.realpath(python):
        rest = sys.argv[:i] + sys.argv[i + 2:]
        os.execv(python, [python] + rest)

# stdout belongs to the protocol. Anything a library prints (even from C) goes to stderr instead.
_protocol = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr
_send_lock = threading.Lock()


def send(message):
    with _send_lock:
        _protocol.write(json.dumps(message) + "\n")
        _protocol.flush()


def log(text):
    print(text, file=sys.stderr, flush=True)


class Engine:
    def __init__(self):
        self.model = None
        self.model_path = None
        self.cancelled = set()
        self.seconds_per_song_second = 2.6  # learned as songs finish

    # MARK: load

    def load(self, path):
        # The app sends the engine's own folder when the Model setting is empty.
        if not path or (os.path.isdir(path) and not os.path.exists(os.path.join(path, "config.json"))):
            path = DEFAULT_MODEL
        if self.model is not None and self.model_path == path:
            send({"ready": {"loadSeconds": 0}})
            return
        start = time.time()
        from mlx_audio.music import load  # imported here so --help and errors stay fast
        self.model = load(path)
        self.model_path = path
        send({"ready": {"loadSeconds": time.time() - start}})

    # MARK: generate

    def generate(self, job):
        jid = job["id"]
        if jid in self.cancelled:
            self.cancelled.discard(jid)
            send({"cancelled": {"id": jid}})
            return
        if self.model is None:
            self.load(None)
        start = time.time()
        seconds = min(float(job.get("maxSeconds") or 240), 360)
        expected = seconds * self.seconds_per_song_second

        # MiniMax doesn't report progress, so estimate it. The heartbeat also tells the app the
        # engine is alive (it restarts engines that stay silent for ten minutes).
        done = threading.Event()

        def heartbeat():
            while not done.wait(0.5):
                elapsed = time.time() - start
                fraction = min(0.97, elapsed / max(expected, 1))
                progress(jid, "composing", fraction, fraction * 0.95, elapsed, seconds)

        threading.Thread(target=heartbeat, daemon=True).start()
        try:
            audio, sample_rate = self.render(job, seconds)
        finally:
            done.set()
        if jid in self.cancelled:
            self.cancelled.discard(jid)
            send({"cancelled": {"id": jid}})
            return

        progress(jid, "encoding", 0, 0.98, time.time() - start, None)
        duration = len(audio) / sample_rate
        write_m4a(audio, sample_rate, job["outputPath"])
        elapsed = time.time() - start
        self.seconds_per_song_second = 0.7 * self.seconds_per_song_second + 0.3 * (elapsed / max(duration, 1))
        send({"finished": {"_0": {
            "id": jid,
            "duration": duration,
            "loudness": loudness(audio),
            "seconds": elapsed,
            "truncated": duration >= seconds - 0.5,
        }}})

    def render(self, job, seconds):
        """Swap this for your own model. Return (samples [frames, channels] float32, sample_rate)."""
        import numpy as np

        # Standard Music's quality setting arrives as 8 / 16 / 32 steps; MiniMax tops out at 30.
        steps = {8: 12, 16: 20, 32: 30}.get(int(job.get("steps", 16)), 20)
        lyrics = job["lyrics"] if not job.get("isInstrumental") else "[instrumental]"
        result = next(self.model.generate(
            text=job["style"],
            lyrics=lyrics,
            duration=seconds,
            steps=steps,
            seed=int(job["seed"]) % 2**31,
        ))
        return np.asarray(result.audio, dtype=np.float32), result.sample_rate


def progress(jid, stage, stage_fraction, overall, elapsed, song_seconds):
    payload = {"stage": stage, "stageFraction": stage_fraction, "overall": overall, "elapsed": elapsed}
    if song_seconds:
        payload["estimatedSongSeconds"] = song_seconds
    send({"progress": {"id": jid, "_1": payload}})


def loudness(audio):
    """Gated loudness in dB (BS.1770 blocks and gates, no K-weighting), matching the built-in
    engine, so Sound Check treats songs from both the same."""
    import numpy as np
    x = audio if audio.ndim > 1 else audio[:, None]
    block, hop = 19200, 4800  # 400 ms blocks, 75% overlap, at 48 kHz (close enough at 44.1)
    energies = np.array([float(np.sum(np.mean(x[i:i + block] ** 2, axis=0)))
                         for i in range(0, max(len(x) - block, 0) + 1, hop)])
    lufs = lambda e: -0.691 + 10 * np.log10(np.maximum(e, 1e-12))
    gated = energies[lufs(energies) > -70]
    if gated.size == 0:
        return -70.0
    relative = gated[lufs(gated) > lufs(gated.mean()) - 10]
    return float(lufs((relative if relative.size else gated).mean()))


def write_m4a(audio, sample_rate, output_path):
    """AAC 256 kbps via macOS's afconvert, written next to the target and moved into place."""
    import soundfile as sf
    folder = os.path.dirname(output_path)
    os.makedirs(folder, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "song.wav")
        sf.write(wav, audio, sample_rate, subtype="FLOAT")
        partial = os.path.join(folder, "." + os.path.basename(output_path) + ".partial.m4a")
        subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "256000", wav, partial],
                       check=True, stdout=subprocess.DEVNULL)
        os.replace(partial, output_path)


def main():
    engine = Engine()
    work = []
    ready = threading.Condition()

    # Read commands on their own thread so `cancel` arrives while a song is rendering.
    def reader():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                command = json.loads(line)
            except json.JSONDecodeError:
                log("unreadable command: " + line[:200])
                continue
            if "cancel" in command:
                engine.cancelled.add(command["cancel"]["id"])
                continue
            with ready:
                work.append(command)
                ready.notify()
        with ready:  # stdin closed: the app is gone
            work.append({"shutdown": {}})
            ready.notify()

    threading.Thread(target=reader, daemon=True).start()
    while True:
        with ready:
            while not work:
                ready.wait()
            command = work.pop(0)
        if "shutdown" in command:
            os._exit(0)
        if "load" in command:
            try:
                engine.load(command["load"].get("modelPath"))
            except Exception as error:  # noqa: BLE001 — report everything to the app
                send({"failed": {"message": f"Couldn't load the model: {error}"}})
        elif "generate" in command:
            job = command["generate"]["_0"]
            try:
                engine.generate(job)
            except Exception as error:  # noqa: BLE001
                log(f"generate failed: {error!r}")
                send({"failed": {"id": job["id"], "message": str(error)}})


if __name__ == "__main__":
    main()
