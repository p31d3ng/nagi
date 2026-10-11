#!/usr/bin/env python3
"""Synthetic local VAD/archive coverage and resource verification; never opens a microphone."""

import json
import math
import pathlib
import random
import struct
import subprocess
import time
import uuid
import wave

project = pathlib.Path(__file__).resolve().parents[1]
root = project / "reports" / ("speech-saving-" + str(uuid.uuid4()))
root.mkdir()
rate = 16000


def read(name):
    with wave.open(str(project / "Fixtures" / (name + ".wav")), "rb") as f:
        assert f.getframerate() == rate and f.getnchannels() == 1
        data = f.readframes(f.getnframes())
    values = list(struct.unpack("<" + "h" * (len(data) // 2), data))
    active = [i for i, v in enumerate(values) if abs(v) > 100]
    return values[max(0, active[0] - 320) : active[-1] + 321]


def write(name, values, channels=1):
    path = root / (name + ".wav")
    with wave.open(str(path), "wb") as f:
        f.setparams((channels, 2, rate, len(values) // channels, "NONE", ""))
        f.writeframes(struct.pack("<" + "h" * len(values), *values))
    return path


def run(name, path, mode="speechOnly", live=False, crash=-1):
    folder = root / (name + "-" + mode)
    command = [
        str(project / ".build/debug/JournalHarness"),
        "speechgate",
        str(folder),
        str(path),
        str(project),
        mode,
        "live" if live else "none",
        str(crash),
    ]
    with (root / (name + "-" + mode + ".log")).open("w") as log:
        p = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        samples = []
        while p.poll() is None:
            raw = (
                subprocess.run(
                    ["ps", "-p", str(p.pid), "-o", "rss=,%cpu="], text=True, capture_output=True
                )
                .stdout.strip()
                .split()
            )
            if len(raw) == 2:
                samples.append({"rss_mib": int(raw[0]) / 1024, "cpu": float(raw[1])})
            time.sleep(0.1)
        code = p.wait()
    assert code == (75 if crash >= 0 else 0), (name, code)
    lines = (root / (name + "-" + mode + ".log")).read_text().splitlines()
    if crash >= 0:
        subprocess.run(
            [str(project / ".build/debug/JournalHarness"), "recover", str(folder)], check=True
        )
        return folder
    result = json.loads(
        next(line[len("GATE-RESULT ") :] for line in lines if line.startswith("GATE-RESULT "))
    )
    result.update(
        name=name,
        peak_rss_mib=max((s["rss_mib"] for s in samples), default=0),
        sampled_mean_cpu_one_core_percent=sum(s["cpu"] for s in samples) / max(1, len(samples)),
    )
    (root / (name + "-" + mode + "-samples.json")).write_text(json.dumps(samples))
    print(json.dumps(result), flush=True)
    return result


english = read("english")
mandarin = read("mandarin")
japanese = read("japanese")
# Generate a genuine short TTS interjection; do not infer speech from transcript text.
subprocess.run(
    ["say", "-v", "Samantha", "-r", "200", "-o", str(root / "oh.aiff"), "Oh!"], check=True
)
subprocess.run(
    [
        "afconvert",
        str(root / "oh.aiff"),
        str(root / "oh.wav"),
        "-f",
        "WAVE",
        "-d",
        "LEI16@16000",
        "-c",
        "1",
    ],
    check=True,
)
with wave.open(str(root / "oh.wav"), "rb") as f:
    data = f.readframes(f.getnframes())
short = list(struct.unpack("<" + "h" * (len(data) // 2), data))
fixtures = {}
truth = {}
for name, speech in [
    ("english", english),
    ("quiet", [int(v * 0.02) for v in english]),
    ("mandarin", mandarin),
    ("japanese", japanese),
    ("short", short),
]:
    values = [0] * (rate * 12) + speech + [0] * (rate * 8)
    fixtures[name] = write(name, values)
    truth[name] = [12, 12 + len(speech) / rate]
stereo = [x for v in ([0] * (rate * 12) + english + [0] * (rate * 8)) for x in (0, v)]
fixtures["stereo-right"] = write("stereo-right", stereo, 2)
truth["stereo-right"] = truth["english"]
fixtures["silence"] = write("silence", [0] * (rate * 30))
rng = random.Random(42)
noise = [int(max(-30000, min(30000, rng.gauss(0, 3500)))) for _ in range(rate * 30)]
fixtures["noise"] = write("noise", noise)
fixtures["wind"] = write(
    "wind", [int(5000 * math.sin(i * 2 * math.pi * 35 / rate)) for i in range(rate * 30)]
)
background = [int(max(-8000, min(8000, rng.gauss(0, 1000)))) for _ in range(rate * 20)]
fixtures["noise-pauses"] = write(
    "noise-pauses", background[: rate * 12] + english + background[rate * 12 :]
)
truth["noise-pauses"] = truth["english"]
results = []
for name, path in fixtures.items():
    result = run(name, path)
    results.append(result)
    if name in ("silence", "noise", "wind"):
        assert result["audio_files"] == 0, (name, result)
    else:
        start, end = truth[name]
        cursor = start
        for r in result["ranges"]:
            if r["end"] < cursor:
                continue
            if r["start"] > cursor + 0.05:
                break
            cursor = max(cursor, r["end"])
        assert cursor >= end - 0.05, (name, truth[name], result["ranges"])
    assert result["peak_buffered_frames"] <= rate * 1.04
continuous = run("english", fixtures["english"], "continuous")
results.append(continuous)
results.append(run("noise-pauses", fixtures["noise-pauses"], "continuous"))
# Multiple speech spans including >45 s omitted silence exercises the live watchdog and wall offsets.
live_values = english + [0] * (rate * 50) + short + [0] * (rate * 5) + english + [0] * (rate * 4)
live_path = write("live-gaps", live_values)
live = run("live-gaps", live_path, live=True)
results.append(live)
assert len(live["ranges"]) >= 3
crash = run("crash", fixtures["english"], crash=15)
import sqlite3

c = sqlite3.connect(crash / "journal.sqlite")
assert c.execute("SELECT COUNT(*) FROM sessions WHERE status='interrupted'").fetchone()[0] == 1
assert c.execute("SELECT COUNT(*) FROM chunks WHERE duration>0").fetchone()[0] > 0
# Thirty-minute zero input: bounded pre-roll, no durable audio, no semantic deletion.
stress = root / "silence-stress.wav"
with wave.open(str(stress), "wb") as f:
    f.setparams((1, 2, rate, rate * 1800, "NONE", ""))
    for _ in range(1800):
        f.writeframesraw(bytes(rate * 2))
result = run("silence-stress", stress)
results.append(result)
assert result["audio_files"] == 0 and result["peak_buffered_frames"] <= rate * 1.04
(root / "summary.json").write_text(json.dumps(results, indent=2))
print("SPEECH-SAVING-PASS " + str(root), flush=True)
