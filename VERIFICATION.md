# Stage 1 verification checkpoint — 10 October 2026

This is a working, locally tested prerelease, not a claim that wearable hardware or real-person recognition has been validated. All test audio was generated with installed macOS TTS voices. No ambient microphone recording or user enrollment occurred.

## Environment and method

M1 Ultra Mac Studio, 20 cores, 128 GB RAM; macOS 26.6.2 (25G83); Xcode; Apple Swift 6.3.3. Native engines and model revisions are pinned in DEPENDENCIES.json. Compiler concurrency was limited to four. ASR uses Metal with two CPU threads. Diarization follows ASR; each worker process exits after its job. Audio jobs are roughly 10 seconds, with a 12-second ASR input guard and 180-second process timeout. Only one ML lane runs in the application.

Wall/CPU/RSS measurements use `/usr/bin/time -l`, with operation timers inside JournalHarness. These are CPU/time/memory proxies, not calibrated energy measurements. Metal/ANE power and unrelated application latency were not measured, so there is no blanket promise of zero slowdown under every workload. Cold model/kernel compilation differs from warm runs. Raw local logs, JSON (including synthetic embeddings), generated audio and databases are in the ignored `reports`, `Fixtures` and test-data directories, and are deliberately not published.

## Actual measurements

| Operation / fixture | Observed result |
|---|---|
| Exact Unified EN offline adapter, 11.76 s synthetic English | 4.02 s process wall; 924,418,048 B max RSS; aligned words returned. Initial CLI engine decode was 529 ms for 11.7 s. |
| Exact Unified EN streaming API | Passed 320 ms feeds and finalization on Metal; retained full output. Upstream streaming timing is absent, so Nagi adds a sequential alignment pass. |
| Whisper Medium, Mandarin | 1.44 s process wall; 889,192,448 B max RSS; correct Chinese passage, emitted in Traditional Chinese. |
| Whisper Medium, Japanese | 0.78 s process wall; 889,012,224 B max RSS; correct Japanese passage with segment timings. |
| Community-1, alternating Samantha / Daniel (~38 s) | 2.91 s wall; 241,926,144 B max RSS; two speakers, stable alternating assignments. |
| Community-1, simultaneous voices (~11.76 s) | 0.66 s wall; 132,136,960 B max RSS; **only one speaker reported despite two voices**. This is a documented failure, not a passed overlap-count assertion. |
| Synthetic local-profile similarity | Same voice cosine 0.989968; other voice 0.115875. The conservative 0.8 threshold / 0.12 margin separates these fixtures. Not proof of real-person accuracy. |
| Ten-minute synthetic capture/import/write | 1.403 s for all original-rate CAF writing; each lossless compression ~0.068–0.070 s. Source was about ten minutes, sealed into 59 chunks. |
| Ten-minute sequential stream + alignment + diarization | 122.08 s wall, 57.26 s user CPU, 22.85 s system CPU; 922,976,256 B max worker RSS. All 59 chunks ended done; zero failed/queued/processing at completion. Approximate RTF 0.21. |
| Decompression | 0.068–0.069 s per tested chunk. |
| Conservative RMS silence gate | 0.007–0.041 s per tested chunk. Continuous archive retained. |
| 16 kHz mono ASR resampling | 0.123–0.124 s per tested chunk. |
| 10,000 transcript rows | 0.175 s insertion in one transaction. |
| 100 FTS searches | 1.268 s total (~12.7 ms/query); returned bounded result sets with speaker filters. |
| Retention and cap eviction on stress metadata | 0.0184 s; whole oldest finalized session evicted. |
| App after window closure | Process remained alive. An idle snapshot reported 0.0% CPU, ~146 MiB RSS. Other resource snapshots include UI interaction bursts and are not labelled idle. |
| Capture-process SIGKILL | Recovery restored a sealed 10.031 s chunk plus a readable 0.186 s open tail. Recovery wall time 3.7 ms. |

The ten-minute fixture was ingested faster than real time to put a backlog on disk; then the queue drained. This is a throughput/backlog and bounded-job stress test, not ten minutes of actual hardware microphone capture. A 40-second worker/resource sample showed queued jobs decreasing from 33 to 13 while only one job was processing. Separate short jobs bound model memory, and the maximum RSS did not increase with the ten-minute duration.

## Functional coverage

All 16 unit tests pass (0 failures, 0.38 seconds). Unit tests cover SQLite rollback, crash/retry states, original 48 kHz stereo preservation, byte-identical gzip round trip, raw/corrected text and Undo, exact replacement rules, English FTS and short Japanese substring search, speaker/language filtering, 48-hour expiry boundary, all derivatives cleanup, previously marked expired jobs, transcript cap/disabled cap, active-recording protection, local cosine uncertainty, and the missing-UID guard. The guard test uses an impossible UID and cannot reach microphone capture.

The deterministic integration script covers English, Mandarin, Japanese, alternating and overlapping voices, digital silence, seeded noise, model-unavailable failure and retry, synthetic embedding comparison, and SIGKILL recovery. It generates new ignored test roots instead of touching a user's journal. Silence skips ASR and retains continuous audio. Noise is intentionally not asserted to produce no transcript: energy VAD is not a learned speech/noise classifier.

Native UI inspection verified the initial timeline, model selections, import dialog, visible processing states, imported transcript, and window closure/reopening. Screenshots were inspected through the native UI tool. Final-name Nagi UI checks also passed startup, missing-input alert (before microphone permission), correction/save/Undo, keyword search at the displayed timestamp, and synthetic audio playback. A blocking backup-exclusion filesystem metadata call discovered by startup sampling was moved off the main thread. The complete synthetic integration suite passed; exact logs are local in `reports/tests.log` and `reports/integration.log`.

## Remaining gaps and limits

- DJI RX connection prompts, live input levels, unplug finalization, TX radio loss, real screen-lock capture, idle sleep assertion and actual sleep/wake behavior have not been exercised against hardware. No permission was assumed for ambient capture. UID/device checks and sleep handlers are implemented; they are not hardware proof.
- Guided user enrollment has explicit controls but has not enrolled the human user. Synthetic voice similarity cannot establish biometric accuracy, fairness, spoof resistance or threshold calibration on real people. Speaker counts remain estimates.
- One wearable microphone cannot guarantee every distant/overlapping voice is transcribed. The generated simultaneous fixture failed to resolve both speakers. Nagi exposes uncertainty and editable labels instead of making a guaranteed count claim.
- Transcript updates are durable-chunk updates (about 10 seconds plus processing), not instant microphone token captions. The current engine needs a second pass for word timing; both raw outputs are retained. Full-session diarization is replaced by bounded chunks plus conservative cross-chunk embedding matching, which may fragment identities.
- Boundary words exposed real recognition errors: SQLite became “SQ Lite” / “SQ Light,” and a chunk boundary split the phrase. Original text is preserved; manual correction and exact post-ASR rules are available. Fuzzy correction and guaranteed decoder vocabulary bias are not implemented.
- The language UI conservatively estimates script; model detected language is retained separately. Mixed-language accuracy has not been benchmarked comprehensively.
- App-off/Mac-off expiry cannot physically delete audio at the instant the deadline passes. Playback is blocked after expiry, and cleanup runs at next active opportunity. Excluding backups is best effort and cannot erase pre-existing filesystem snapshots.
- Transcript capacity is a UTF-8 content/history cap, not a hard total SQLite-file cap. Metadata/index overhead can exceed it. UI browsing/search limits are explicit.
- `sandbox-exec` is a deprecated macOS mechanism used here to deny worker network access; future distribution should use a reviewed sandboxed XPC helper. Ad-hoc development signing is not notarized distribution.
- A valid writable local SQLite store is required; corrupt-database rescue beyond normal interrupted-job recovery remains a gap. There is no cloud recovery or upload implementation.
