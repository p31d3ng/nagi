#!/usr/bin/env python3
"""Compare uncut vs hard-cut vs contextual ASR. Synthetic inputs only; raw outputs retained."""

import pathlib, subprocess, wave, json, sqlite3, uuid

p = pathlib.Path(__file__).resolve().parents[1]
out = p / "reports" / ("boundary-" + str(uuid.uuid4()))
out.mkdir(parents=True)
model = p / "Models/parakeet-unified-en-0.6b-Q8_0.gguf"
worker = p / "bin/ASRWorker"
h = p / ".build/debug/JournalHarness"
with wave.open(str(p / "Fixtures/english.wav")) as f:
    source = f.readframes(f.getnframes())
    rate = f.getframerate()


def write(path, data):
    with wave.open(str(path), "wb") as f:
        f.setparams((1, 2, rate, len(data) // 2, "NONE", ""))
        f.writeframes(data)


def run(args, log):
    with (out / log).open("w") as f:
        subprocess.run(
            [str(x) for x in args], stdout=f, stderr=subprocess.STDOUT, check=True, timeout=180
        )


run([worker, model, p / "Fixtures/english.wav", out / "uncut.json"], "uncut.log")
results = {"uncut": json.loads((out / "uncut.json").read_text())}
for shift in [0, 0.25, 0.5, 0.75]:
    name = f"shift-{shift}"
    audio = b"\0\0" * int(shift * rate) + source
    fixture = out / (name + ".wav")
    write(fixture, audio)
    hard = []
    for i, offset in enumerate(range(0, len(audio), rate * 10 * 2)):
        chunk = out / (name + f"-{i}.wav")
        write(chunk, audio[offset : offset + rate * 10 * 2])
        result = out / (name + f"-{i}.json")
        run([worker, model, chunk, result], name + f"-{i}.log")
        hard.append(json.loads(result.read_text()))
    data = out / (name + "Data")
    run([h, "import", data, fixture], name + "-import.log")
    run([h, "process", data, p], name + "-context.log")
    with sqlite3.connect(data / "journal.sqlite") as db:
        rows = list(db.execute("SELECT offset,end,raw,speaker FROM segments ORDER BY offset"))
        statuses = dict(db.execute("SELECT status,count(*) FROM chunks GROUP BY status"))
        assert set(statuses) == {"done"}, statuses
        assert all(0 <= start <= end <= len(audio) / 2 / rate + 0.01 for start, end, _, _ in rows)
        text = " ".join(r[2] for r in rows).lower()
        assert text.count("kyoto") == 1 and text.count("parakeet") == 1 and " get," not in text, (
            name,
            text,
        )
        results[name] = {
            "hard_cut": [r["text"] for r in hard],
            "context_rows": rows,
            "context_text": " ".join(r[2] for r in rows),
            "statuses": statuses,
        }
(out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))
print(out)
print(
    json.dumps(
        {
            k: v if k == "uncut" else {"hard_cut": v["hard_cut"], "context_text": v["context_text"]}
            for k, v in results.items()
        },
        indent=2,
    )
)
