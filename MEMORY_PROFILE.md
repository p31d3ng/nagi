# v0.1.2 memory investigation — 11 October 2026

The two-hour **real-time** synthetic production pipeline passed. The earlier sustained Foundation-object retention was addressed with explicit autorelease boundaries. This is evidence from a finite synthetic run, not a 24-hour hardware or real-speaker guarantee.

## What changed

- Capture, processing, retention and playback queues use work-item autorelease pools. Long processing drains release temporary Foundation objects after each job; synthetic/import readers release them per buffer.
- Input level/time updates belong to a separate observable meter, so they do not invalidate the whole timeline. Transcript rows render lazily. Timeline details/failures are cached outside view rendering; failure lists are capped at 20. Unchanged sessions, segments, devices and speaker choices avoid redundant publication.
- Failure-log reads take only the last 4 KiB rather than loading an entire log. Speaker matching loads/retains at most 128 identities per conversation; further uncertain identities remain Unknown. Existing identities remain matchable.
- Indexed session/offset and offset retrieval avoid full transcript-table scans and temporary sorting for bounded timeline queries. Recent sessions remain capped at 500 and transcript/search rows at 2,000.
- Stopping capture releases its writer even if finalization throws. Rebuilds atomically replace executables rather than overwriting mapped binaries.
- Synthetic test apps have distinct bundle identities, isolated data roots, an orange banner, a test window title and disabled recording/settings controls. The mode/data identity persists in the test bundle, so reopening it without environment flags cannot become normal microphone mode. Normal Nagi remains separately available.

## Method and actual evidence

M1 Ultra, 20 CPU cores, 128 GB RAM; macOS 26.6.2; Swift 6.3.3. The exact pinned Unified EN model and sequential Community-1 worker pipeline were used. Generated Samantha English WAV: 16 kHz mono, 11.70275 seconds, repeated continuously. No microphone or human enrollment opened.

A short A/B comparison used 300 seconds of synthetic audio at 4× speed. After the first 30 wall seconds, sampled host RSS slopes were **3.59 MiB/min before / 0.186 MiB/min after**. Baseline/fixed live heaps were 1,794,608 / 924,544 bytes (snapshots at 27 / 54 wall seconds, respectively). Retained Foundation byte-storage objects fell from **1,560 / 331,264 bytes** to **9 / 2,352 bytes**; Swift string storage fell from 150,976 to 3,280 bytes. Both native leak scans reported zero leaks: this was deferred autorelease retention, not evidence of an unreachable-object leak.

The full producer used the production `ChunkWriter.enqueue`/copy/write/seal path, durable SQLite queue, compression/VAD, streaming plus alignment ASR, and sequential diarization. A separate SwiftUI process observed the same synthetic journal every two seconds and exercised meter updates at 12.5 Hz. It was a read-only observer, not actual microphone capture in the GUI process.

Confirmed recording start: **2026-10-10 22:15:27.873797 UTC**. The producer accepted all 115,200,000 frames and finished processing in **7,205.190 seconds**. Controller wall was **7,446.579 seconds**, including two-minute idle controls before/after. Capture was paced at 1×; controller wall is not an ASR compute RTF. The original test helper backdated chunk capture metadata by two hours; production capture uses the actual start time. Future synthetic runs now use the actual start time too.

| Measurement | Actual result |
|---|---:|
| Recorded audio / chunks | 7,200.0 seconds / 720 exact ten-second chunks |
| Gaps / rejected frames / failed jobs | 0 / 0 / 0 |
| Final queue | Empty; all 720 jobs done |
| Queue maximum | 1 in periodic samples; 2 in seal callbacks (bounded look-ahead) |
| Final transcript rows / speaker catalog | 1,481 / 1 |
| Exact sample verification | All 115,200,000 Float32 samples matched the repeated source |
| Continuous audio SHA-256 | `a34a1abfa2afec723edef0ac51a8cd5f7f010177eb93ea13399f54e9821e9a5e` |
| Sampled peak worker RSS | 904,080 KiB = 882.9 MiB |
| Peak test-journal disk | 277,151,730 bytes = 264.3 MiB; budget 2 GiB |
| Host RSS, first / final six-sample medians | 16.92 / 22.83 MiB |
| Host sampled RSS maximum | 23.44 MiB |
| Host last-30-minute RSS slope | +0.0133 MiB/min (about 2.27 KiB/chunk) |
| Host live heap, early / final | 882,256 / 912,448 bytes (0.84 / 0.87 MiB) |
| Host final live-heap change | About 30 KiB total across two hours; roughly 42 bytes/chunk |
| Host native leak scans | Zero at every saved checkpoint |
| UI RSS, first / final six-sample medians | 143.64 / 134.49 MiB |
| UI sampled RSS maximum | 145.42 MiB |
| UI last-30-minute RSS slope | +0.0396 MiB/min (about 6.76 KiB/chunk) |
| UI live heap, early / final | 24,481,047 / 27,152,850 bytes (23.35 / 25.89 MiB) |
| UI live heap after first ten minutes | 26,371,554 bytes; subsequent growth about 0.75 MiB |
| UI native leak scans | 15,040 bytes initially; **15,184 bytes unchanged** from ten minutes through final scan |
| Host / UI median process CPU during recording | 0.3% / 7.25% of one CPU core |
| UI post-run idle median process CPU | 0.35% of one core; transition/profiling spikes excluded from interpretation |

RSS was sampled via `ps` every 0.5 seconds; persisted snapshots are about ten seconds apart. Worker peaks may miss shorter spikes. `heap -s`, `vmmap -summary` and `leaks` ran on Nagi-owned processes at bounded checkpoints. RSS includes working-set/allocator effects; it is not the same as live heap or private physical footprint. An inspected 1.4 MiB host RSS step still had only 913,824 live bytes and about 6.8 MiB physical footprint. At that checkpoint, malloc fragmentation/resident allocator space exceeded live allocations. UI leak roots include macOS `LNDaemonApplicationInterface` XPC cycles and small NSArray allocations; they were not attributed to a Nagi-owned growing collection. They remain reported, rather than being called zero leaks.

The host's major prior retention trend is resolved within this measured window. Small RSS/cache growth and a growing bounded transcript array remain visible; the finite test cannot prove an all-day plateau. ML weights/activations live in separate exiting workers, not a permanent parent model cache. No 2-hour sample/audio buffer collection is held in memory.

CPU percentages are process proxies (100% means one core), not calibrated energy or GPU/ANE measurements. No unrelated heavy workload was introduced. User interaction, brief build/UI verification work and native profiler activity occurred during early setup; post-warm-up and final-window trends are reported separately. Ordinary desktop latency under competing GPU loads was not benchmarked. No screen lock or global security setting was changed. Test-only idle system-sleep prevention was released on completion.

## UI capacity control and reproducibility

A separate five-minute 100,000-row generated database control exercises the 2,000-row display bound and meter updates, without capture or ML. The session query initially scanned/sorted the table. Creating the two timeline indexes took **0.079 seconds**; `EXPLAIN QUERY PLAN` then selected the session/offset index and removed the full scan/temporary sort. The control completed in **312.06 seconds** (300-second observation plus profiler overhead), with **100,000 database rows** and the **2,000-row display bound**. Warm/final six-sample RSS medians were **143.04 / 146.66 MiB**, maximum **146.69 MiB**. Native live heaps were **22,636,546 / 24,252,593 bytes**; leak scans flagged **14,128 / 14,544 bytes**. This short control includes UI/cache warm-up and cannot prove an all-day plateau. Late process CPU median was **9.3% of one core**, versus an earlier pre-index median of **11.1%**; these observational windows include warm-up and are not a rigorous causal CPU benchmark. The query-plan change is verified directly. The synthetic database occupied **49.25 MiB**. The native screenshot/accessibility inspection showed lazy visible rows and the orange test banner/disabled controls. No capture or ASR ran in this control.

Local control evidence: `reports/ui-memory-9ff05e84-38cb-4f9c-8af8-0b549e3558a6/`, including samples, native snapshots, index-control plan and summary. The regression suite now has **37 tests, zero failures**, completed in **3.896 seconds**; local log: `reports/final-37-tests.log`. App signing verification and shell/Python script syntax checks passed.

```sh
scripts/build.sh
scripts/run-normal.sh
# Full synthetic run: no microphone, separate test bundle and journal.
python3 scripts/memory-soak.py 7200 120
python3 scripts/analyze-memory.py reports/memory-soak-<run-id>
python3 scripts/check-soak-audio.py reports/memory-soak-<run-id>/Data
# Separate generated database/UI control; no ASR or audio capture.
python3 scripts/ui-memory.py 100000 300
```

The original long run's observer used the original Nagi bundle identity; the user pressed Start and saw the older test guard, “This synthetic monitor never opens a microphone.” That was not a microphone permission failure. The long test stayed intact. Updated distinct test identity/title/banner/disabled controls were verified in a separate short run and the capacity control. `scripts/run-normal.sh` clears test/data overrides and opens normal Nagi in the regular Application Support journal; avoid multiple normal instances against the same journal.

Local evidence (ignored, not uploaded): `reports/memory-soak-2d44fbc7-17e4-4f4c-ab4f-64dae1c2ddfd/` contains final results, streamed samples, native heap/vmmap/leaks snapshots, analysis, continuity verification and generated audio/database. `reports/soak-f3d758dc-a588-40ae-8d34-b497c4fbb3b6/` and `reports/soak-2d24d5ae-974c-4ccc-961e-0e476f38a771/` contain the A/B samples. No audio, transcript text, speaker embeddings, raw memory dumps or weights are published in Git.

## Remaining limits

Real DJI RX/TX behavior, microphone capture, screen-lock/sleep/wake hardware behavior and the human voice profile are still untested. Synthetic speaker matching is not evidence of human identification accuracy. Multilingual/overlap/noise/crash/retry/retention tests from the earlier checkpoint remain documented in VERIFICATION.md; the long memory run used English synthetic speech only. A full-day hardware run and competing-workload latency/energy measurements remain future validation. Corrupt-store rescue and notarized/sandboxed distribution remain gaps. Stage 2 uploads/deployment are absent.
