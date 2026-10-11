#!/usr/bin/env python3
"""Timestamped synthetic speech latency through the production write/live path. No microphone."""

import json
import math
import pathlib
import re
import statistics
import struct
import subprocess
import sys
import time
import uuid
import wave

project = pathlib.Path(__file__).resolve().parents[1]
folder = project / "reports" / ("latency-" + str(uuid.uuid4()))
folder.mkdir()
markers = [
    "lemon",
    "river",
    "camera",
    "window",
    "garden",
    "silver",
    "forest",
    "pencil",
    "orange",
    "planet",
    "coffee",
    "music",
]
sequence = []
truth = []
references = []
for i, marker in enumerate(markers):
    phrase = "The next word is " + marker + "."
    aiff = folder / (marker + ".aiff")
    wav = folder / (marker + ".wav")
    subprocess.run(
        ["say", "-v", "Samantha" if i % 2 == 0 else "Daniel", "-r", "155", "-o", str(aiff), phrase],
        check=True,
    )
    subprocess.run(
        ["afconvert", str(aiff), str(wav), "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"], check=True
    )
    with wave.open(str(wav), "rb") as f:
        pcm = list(struct.unpack("<" + "h" * f.getnframes(), f.readframes(f.getnframes())))
    speech = [i for i, v in enumerate(pcm) if abs(v) > 100]
    assert speech
    # Waveform-based end of a known marker phrase, approximate phonetic timing (±~20 ms).
    lo = max(0, speech[0] - 320)
    hi = min(len(pcm), speech[-1] + 321)
    clip = pcm[lo:hi]
    start = len(sequence) / 16000
    end = start + (speech[-1] - lo + 1) / 16000
    sequence.extend(clip)
    truth.append({"marker": marker, "phrase_start": start, "speech_end": end})
    references.extend(re.findall(r"[a-z]+", phrase.lower()))
    sequence.extend([0] * 6400)
fixture = folder / "timestamped.wav"
with wave.open(str(fixture), "wb") as f:
    f.setparams((1, 2, 16000, len(sequence), "NONE", ""))
    f.writeframes(struct.pack("<" + "h" * len(sequence), *sequence))
(folder / "truth.json").write_text(json.dumps(truth, indent=2))


def wer(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, word in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (word != other)))
        previous = current
    return previous[-1] / max(1, len(reference))


def percentile(values, p):
    return sorted(values)[min(len(values) - 1, int((len(values) - 1) * p))]


results = []
for mode in ["accuracy", "balanced"]:
    data = folder / (mode + "Data")
    started = time.monotonic()
    log_path = folder / (mode + ".log")
    with log_path.open("w") as log:
        process = subprocess.Popen(
            [
                str(project / ".build/debug/JournalHarness"),
                "live",
                str(data),
                str(fixture),
                str(project),
                str(len(sequence) / 16000),
                "-1",
                "1",
                "capture",
                mode,
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        samples = []
        while process.poll() is None:
            rows = []
            for line in subprocess.check_output(
                ["ps", "-axo", "pid,ppid,rss,%cpu,comm"], text=True
            ).splitlines()[1:]:
                f = line.strip().split(None, 4)
                if len(f) == 5:
                    rows.append((int(f[0]), int(f[1]), int(f[2]), float(f[3]), f[4]))
            family = {process.pid}
            for _ in range(4):
                family.update(row[0] for row in rows if row[1] in family)
            live = [
                row
                for row in rows
                if row[0] == process.pid or "LiveASRWorker" in row[4] and row[0] in family
            ]
            samples.append(
                {
                    "wall": time.monotonic() - started,
                    "rss_kib": sum(row[2] for row in live),
                    "cpu": sum(row[3] for row in live),
                }
            )
            time.sleep(0.25)
        assert process.wait() == 0, log_path.read_text()[-1000:]
    lines = log_path.read_text().splitlines()
    events = [json.loads(line) for line in lines if line.startswith('{"audio"')]
    assert events and "LIVE-PASS" in lines[-1]
    first = {}
    revoked = 0
    prior = ""
    for e in events:
        words = re.findall(r"[a-z]+", e["text"].lower())
        for marker in markers:
            if marker in words and marker not in first:
                first[marker] = e["wall"]
        # A conservative revision proxy: words disappearing from an already exposed hypothesis.
        old = set(re.findall(r"[a-z]+", prior.lower()))
        revoked += len(old - set(words)) if e["offset"] == 0 else 0
        prior = e["text"]
    lags = [first[t["marker"]] - t["speech_end"] for t in truth[1:] if t["marker"] in first]
    final = " ".join(e["text"] for e in events if e["final"])
    active = [s for s in samples if 2 < s["wall"] < len(sequence) / 16000]
    result = {
        "mode": mode,
        "duration": len(sequence) / 16000,
        "first_nonempty_seconds": events[0]["wall"],
        "steady_marker_lag_p50": percentile(lags, 0.5),
        "steady_marker_lag_p90": percentile(lags, 0.9),
        "steady_marker_lag_max": max(lags),
        "recognized_markers": len(first),
        "total_markers": len(markers),
        "preview_final_wer": wer(references, re.findall(r"[a-z]+", final.lower())),
        "revoked_word_proxy": revoked,
        "updates": len(events),
        "active_mean_cpu_one_core_percent": statistics.mean(s["cpu"] for s in active),
        "peak_live_family_rss_mib": max(s["rss_kib"] for s in active) / 1024,
        "continuity_pass": True,
        "marker_lags": lags,
    }
    results.append(result)
    (folder / (mode + "-samples.json")).write_text(json.dumps(samples))
    print(json.dumps(result), flush=True)
(folder / "summary.json").write_text(
    json.dumps(
        {
            "folder": str(folder),
            "method": "Lag from approximate waveform end of a known marker word to its first appearance in the production live snapshot; first marker excluded from steady distribution. Negative means hypothesis preceded the trimmed speech end. No GUI polling delay included.",
            "results": results,
        },
        indent=2,
    )
)
print("EVIDENCE", folder, flush=True)
