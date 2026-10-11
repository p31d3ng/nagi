#!/usr/bin/env python3
"""Synthetic live/batch comparison. Never opens a microphone or reads private recordings."""

import json
import pathlib
import statistics
import subprocess
import sys
import time
import uuid

project = pathlib.Path(__file__).resolve().parents[1]
mode = sys.argv[1] if len(sys.argv) > 1 else "live"
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 120
kill_at = float(sys.argv[3]) if len(sys.argv) > 3 else -1
speed = float(sys.argv[4]) if len(sys.argv) > 4 else 1
fixture = pathlib.Path(sys.argv[5]) if len(sys.argv) > 5 else project / "Fixtures/english.wav"
folder = project / "reports" / ("live-profile-" + mode + "-" + str(uuid.uuid4()))
folder.mkdir()
data = folder / "Data"
if mode == "live":
    command = [
        str(project / ".build/debug/JournalHarness"),
        "live",
        str(data),
        str(fixture),
        str(project),
        str(duration),
        str(kill_at),
        str(speed),
    ]
else:
    command = [
        str(project / ".build/debug/JournalHarness"),
        "soak",
        str(data),
        str(fixture),
        str(project),
        str(duration),
        "1",
    ]
with (folder / "run.log").open("w") as log:
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    samples = []
    while process.poll() is None:
        raw = subprocess.check_output(["ps", "-axo", "pid,ppid,rss,%cpu,comm"], text=True)
        rows = []
        for line in raw.splitlines()[1:]:
            fields = line.strip().split(None, 4)
            if len(fields) == 5:
                rows.append(
                    (int(fields[0]), int(fields[1]), int(fields[2]), float(fields[3]), fields[4])
                )
        family = {process.pid}
        for _ in range(5):
            family.update(row[0] for row in rows if row[1] in family)
        selected = [row for row in rows if row[0] in family]
        sample = {
            "wall": time.monotonic() - started,
            "rss_kib": sum(row[2] for row in selected),
            "cpu_one_core_percent": sum(row[3] for row in selected),
            "processes": selected,
        }
        samples.append(sample)
        with (folder / "samples.ndjson").open("a") as out:
            out.write(json.dumps(sample) + "\n")
        time.sleep(0.5)
    code = process.wait()
summary = {
    "mode": mode,
    "duration": duration,
    "kill_at": kill_at,
    "exit": code,
    "wall": time.monotonic() - started,
    "peak_family_rss_mib": max(s["rss_kib"] for s in samples) / 1024,
    "median_family_cpu_one_core_percent": statistics.median(
        s["cpu_one_core_percent"] for s in samples
    ),
    "mean_family_cpu_one_core_percent": statistics.mean(s["cpu_one_core_percent"] for s in samples),
    "samples": len(samples),
    "folder": str(folder),
}
if mode == "live":
    events = [
        json.loads(line)
        for line in (folder / "run.log").read_text().splitlines()
        if line.startswith('{"audio"')
    ]
    if events:
        summary["first_nonempty_text_seconds"] = events[0]["wall"]
        summary["median_output_audio_cursor_lag_seconds"] = statistics.median(
            e["wall"] - e["offset"] - e["audio"] for e in events
        )
        summary["updates"] = len(events)
    summary["continuity_pass"] = "LIVE-PASS" in (folder / "run.log").read_text()
(folder / "summary.json").write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2), flush=True)
sys.exit(code)
