#!/usr/bin/env python3
"""Synthetic 100,000-row UI capacity control; no capture/ML or private data.
Run after the recording soak. Uses a separate test app identity and data root.
"""

import pathlib, subprocess, plistlib, sqlite3, uuid, json, os, time, sys

p = pathlib.Path(__file__).resolve().parents[1]
out = p / "reports" / ("ui-memory-" + str(uuid.uuid4()))
out.mkdir(parents=True)
data = out / "Data"
rows = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 300
subprocess.run(
    [str(p / ".build/debug/JournalHarness"), "recover", str(data)],
    check=True,
    stdout=subprocess.DEVNULL,
)
with sqlite3.connect(data / "journal.sqlite") as db:
    id = str(uuid.uuid4())
    db.execute(
        "INSERT INTO sessions(id,title,started,device,model,status) VALUES(?,?,?,?,?,'recording')",
        (
            id,
            "Synthetic UI capacity · no audio",
            time.time(),
            "generated database fixture",
            "unified",
        ),
    )
    text = "Synthetic capacity fixture. Meetings, plans, and conversations stay local. No microphone recording or voice enrollment occurs here. "
    db.executemany(
        "INSERT INTO segments(session,offset,end,raw,corrected,speaker,language,chunk) VALUES(?,?,?,?,?,?,?,?)",
        ((id, i, i + 1, text + str(i), text + str(i), "Speaker 2", "en", "") for i in range(rows)),
    )
test_app = out / "Nagi Synthetic UI Test.app"
subprocess.run(["/bin/cp", "-cR", str(p / "build/Nagi.app"), str(test_app)], check=True)
plist_path = test_app / "Contents/Info.plist"
with plist_path.open("rb") as f:
    plist = plistlib.load(f)
plist.update(
    CFBundleIdentifier="local.nagi.synthetic-ui." + out.name[-12:],
    CFBundleName="Nagi Synthetic UI Test",
    CFBundleDisplayName="Nagi Synthetic UI Test",
    NagiSyntheticTest=True,
    NagiSyntheticData=str(data),
)
with plist_path.open("wb") as f:
    plistlib.dump(plist, f)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(test_app)], check=True)
log = (out / "app.log").open("w")
app = subprocess.Popen(
    [str(test_app / "Contents/MacOS/Nagi")],
    env=os.environ | {"NAGI_DATA": str(data), "NAGI_SYNTHETIC_MONITOR": "1"},
    stdout=log,
    stderr=subprocess.STDOUT,
)
wake = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(app.pid)])
start = time.monotonic()
samples = []
print(
    json.dumps(
        {"folder": str(out), "app_pid": app.pid, "database_rows": rows, "duration": duration}
    ),
    flush=True,
)
try:
    while time.monotonic() - start < duration:
        if app.poll() is not None:
            raise RuntimeError("UI test exited unexpectedly")
        stats = (
            subprocess.check_output(["ps", "-p", str(app.pid), "-o", "rss=,%cpu=,time="], text=True)
            .strip()
            .split()
        )
        samples.append(
            {
                "wall": time.monotonic() - start,
                "rss_kib": int(stats[0]),
                "cpu_percent": float(stats[1]),
                "cpu_time": stats[2],
            }
        )
        (out / "samples.json").write_text(json.dumps(samples, indent=2))
        if len(samples) in [7, int(duration / 5) - 1]:
            for tool, args in [("heap", ["-s"]), ("vmmap", ["-summary"]), ("leaks", [])]:
                with (out / f'{tool}-{int(samples[-1]["wall"])}.txt').open("w") as f:
                    subprocess.run(
                        ["/usr/bin/" + tool, *args, str(app.pid)],
                        stdout=f,
                        stderr=subprocess.STDOUT,
                        timeout=20,
                    )
        time.sleep(5)
    result = {
        "database_rows": rows,
        "duration": duration,
        "wall": time.monotonic() - start,
        "folder": str(out),
        "display_limit": 2000,
        "disk_bytes": sum(f.stat().st_size for f in data.rglob("*") if f.is_file()),
    }
    (out / "results.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
finally:
    if app.poll() is None:
        app.terminate()
        app.wait(timeout=10)
    if wake.poll() is None:
        wake.terminate()
        wake.wait(timeout=5)
    log.close()
