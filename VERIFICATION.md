# Stage 1 verification checkpoint — 10 October 2026

This is a working, locally tested prerelease, not a claim that wearable hardware or real-person recognition has been validated. All test audio was generated with installed macOS TTS voices. No ambient microphone recording or user enrollment occurred.

## Environment and method

M1 Ultra Mac Studio, 20 cores, 128 GB RAM; macOS 26.6.2 (25G83); Xcode; Apple Swift 6.3.3. Native engines and model revisions are pinned in DEPENDENCIES.json. Compiler concurrency was limited to four. ASR uses Metal with two CPU threads. Diarization follows ASR; each worker process exits after its job. Audio jobs are roughly 10 seconds, with a 12-second ASR input guard and 180-second process timeout. Only one ML lane runs in the application.

Wall/CPU/RSS measurements use `/usr/bin/time -l`, with operation timers inside JournalHarness. These are CPU/time/memory proxies, not calibrated energy measurements. Metal/ANE power and unrelated application latency were not measured, so there is no blanket promise of zero slowdown under every workload. Cold model/kernel compilation differs from warm runs. Raw local logs, JSON (including synthetic embeddings), generated audio and databases are in the ignored `reports`, `Fixtures` and test-data directories, and are deliberately not published.

## Initial v0.1 checkpoint measurements

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

## Initial v0.1 functional coverage

All 16 unit tests pass (0 failures, 0.38 seconds). Unit tests cover SQLite rollback, crash/retry states, original 48 kHz stereo preservation, byte-identical gzip round trip, raw/corrected text and Undo, exact replacement rules, English FTS and short Japanese substring search, speaker/language filtering, 48-hour expiry boundary, all derivatives cleanup, previously marked expired jobs, transcript cap/disabled cap, active-recording protection, local cosine uncertainty, and the missing-UID guard. The guard test uses an impossible UID and cannot reach microphone capture.

The deterministic integration script covers English, Mandarin, Japanese, alternating and overlapping voices, digital silence, seeded noise, model-unavailable failure and retry, synthetic embedding comparison, and SIGKILL recovery. It generates new ignored test roots instead of touching a user's journal. Silence skips ASR and retains continuous audio. Noise is intentionally not asserted to produce no transcript: energy VAD is not a learned speech/noise classifier.

Native UI inspection verified the initial timeline, model selections, import dialog, visible processing states, imported transcript, and window closure/reopening. Screenshots were inspected through the native UI tool. Final-name Nagi UI checks also passed startup, missing-input alert (before microphone permission), correction/save/Undo, keyword search at the displayed timestamp, and synthetic audio playback. A blocking backup-exclusion filesystem metadata call discovered by startup sampling was moved off the main thread. A subsequent Documents database-open wait prompted moving default storage into Nagi’s own Application Support directory and bundling runtime helpers/models, without changing global privacy settings. The complete synthetic integration suite passed; exact logs are local in `reports/tests.log` and `reports/integration.log`.

The final bundled-runtime smoke test processed a generated English fixture through the app bundle's own ASR and Community-1 helpers/models in 8.413 seconds, with transcript output and no pending worker error. Final bundled app startup and both installed model indicators were inspected successfully with the Application Support data location.

## Remaining gaps and limits (updated after hardening)

- DJI RX connection prompts, live input levels, unplug finalization, TX radio loss, real screen-lock capture, idle sleep assertion and actual sleep/wake behavior have not been exercised against hardware. No permission was assumed for ambient capture. UID/device checks and sleep handlers are implemented; they are not hardware proof.
- Guided user enrollment has explicit controls but has not enrolled the human user. Synthetic voice similarity cannot establish biometric accuracy, fairness, spoof resistance or threshold calibration on real people. Speaker counts remain estimates.
- One wearable microphone cannot guarantee every distant/overlapping voice is transcribed. The generated simultaneous fixture failed to resolve both speakers. Nagi exposes uncertainty and editable labels instead of making a guaranteed count claim.
- Transcript updates are durable-chunk updates, not instant microphone token captions. Unified EN waits for a neighboring chunk (about 20 seconds plus processing during recording). It uses canonical streaming words with approximate timing from an independent offline pass; both raw outputs are retained. Whisper currently uses hard chunk boundaries and coarser segment timing. Full-session diarization is replaced by bounded chunks plus conservative cross-chunk embedding matching, which may fragment identities.
- SQLite becomes “SQ Lite” / “SQ Light” even in uncut audio. Context and canonical streaming words fixed the tested extra boundary fragments but cannot guarantee recognition/timing correctness or all future boundary cases. Original outputs remain preserved; exact rules and manual correction are available. Fuzzy correction/decode-time bias is not implemented.
- The language UI conservatively estimates script; model detected language is retained separately. Mixed-language accuracy has not been benchmarked comprehensively.
- App-off/Mac-off expiry cannot physically delete audio at the instant the deadline passes. Playback is blocked after expiry, and cleanup runs at next active opportunity. Excluding backups is best effort and cannot erase pre-existing filesystem snapshots.
- Transcript capacity is a UTF-8 content/history cap, not a hard total SQLite-file cap. Metadata/index overhead can exceed it. UI browsing/search limits are explicit.
- `sandbox-exec` is a deprecated macOS mechanism used here to deny worker network access; future distribution should use a reviewed sandboxed XPC helper. Ad-hoc development signing is not notarized distribution.
- A valid writable local SQLite store is required; corrupt-database rescue beyond normal interrupted-job recovery remains a gap. There is no cloud recovery or upload implementation.

## v0.1.1 hardening — actual additional evidence

The original ten-minute file is **597.02925 seconds** (9,552,468 frames at 16 kHz). It consisted of repeated synthetic speech plus silence, rounded down to complete repeats. The original writer rolled only after whole 4,096-frame buffers, so full mono chunks were **10.24 seconds**; hence **59 chunks**, not 60. No claim that this was 600 seconds of microphone capture is made. Import used the production ChunkWriter.write path and the same production Processor compression, conservative VAD, ASR streaming + alignment, and sequential Community-1 jobs, but **bypassed enqueue/backpressure and real-time pacing**.

The new writer splits at exact original-rate frame boundaries. A regression concatenates every saved Float32 sample and compares it with the source, covering both boundaries and repeated words. Context readers loop over partial AVAudioFile reads. A deterministic blocked-sink test admitted exactly 64 buffers, rejected further buffers, emitted one gap error, and finalized accepted audio. Production recording callbacks persist that error as a gap and stop; no ML runs on the capture callback.

### Boundary comparison

`scripts/boundary.py` compares the same synthetic English passage uncut, hard-cut at ten seconds, and through contextual production processing, with shifts of 0, 0.25, 0.5 and 0.75 seconds. Uncut alignment yields “SQ Lite,” proving that this spelling error is independent of the chunk boundary. Hard cuts produced a trailing “and” and, at the 0.75-second shift, “Kioto.” Context alone exposed a separate offline insertion, “Get,” absent from streaming output.

Canonical streaming text plus exact-token timing alignment removed that offline insertion. All four recorded final runs contained Kyoto and Parakeet exactly once and no extra Get; raw streaming/offline outputs remain in SQLite. Legitimate repeated tokens are kept. Word times are estimates; interpolation is used where decoder outputs disagree. This is four deterministic regression cases, not a general proof against boundary errors. Final raw results are in `reports/hardening-boundary-final.log` and its recorded boundary run directory.

### Speaker overlap

SDK output is now nonexclusive. Additionally, a bounded pass of the **same pinned Community-1 segmentation model** retains powerset overlap hints before identity clustering. On the generated two-voice mixture, clustering still reports **one identity**, but the detector flags **0–5.586 seconds**. These spans receive **Unknown · possible overlap**, even with a matching Me profile, and their ASR text remains. This does not recover the missing quieter transcript or establish an accurate count. Whole synthetic solo English returned no overlap hints.

The overlap worker took **2.47 seconds wall, 0.99 user, 0.19 system, 183,336,960 B max RSS**; the solo worker took **0.81 seconds, 151,355,392 B max RSS**. Timing includes both diarization and overlap probing, not a measured isolated delta. False positives and missed overlaps remain possible.

### Production enqueue soaks

`scripts/soak.py` injects only generated buffers through **ChunkWriter.enqueue**, its bounded asynchronous writer and production processing queue. It seals chunks while ASR and diarization run sequentially on a separate lane; it does not use CoreAudio hardware capture. Memory/CPU snapshots use `ps` at 0.5-second polling, retaining samples about every ten seconds. Peak worker RSS is the maximum observed at polling, not a calibrated high-water mark. Brief compiler and non-ML verification activity also occurred on the shared Mac.

| Run | Actual results |
|---|---|
| 30 minutes of audio, 4× input pace | **1,800.000 s**, **180 chunks**, **28,800,000 accepted frames**, **zero gaps**, **532.873 s harness wall** (533.595 s controller wall). All chunks done; no failed/queued/processing remaining. Queue built to **31** at the end of deliberately accelerated input, then drained. Processing was slower than 4× input, so this is not a no-backlog claim at that speed. Sampled peak worker RSS **903,776 KiB (882.6 MiB)**. |
| Final worker, 5 minutes at real-time input pace | **300.000 s**, **30 chunks**, **4,800,000 accepted frames**, **zero gaps**, **305.174 s harness wall** (305.256 s controller). All chunks done. Queue stayed at **1** in periodic samples, **2** at sealing callbacks, then drained. Sampled peak worker RSS **899,936 KiB (878.8 MiB)**. |

After processing, `scripts/check-soak-audio.py` parsed the gzip CAF archives using the documented CAF endian flags and compared **every Float32 sample** to the repeated generated source. Both runs passed exact continuity. The 30-minute archive SHA-256 is `781c20144f65718ac5e15c77475fbab504efc92bdf29cb3939fa7da1edaee664`. This verifies archive continuity, not word accuracy.

Parent RSS in the accelerated run rose from about **16.5 MiB to 29.2 MiB**; first/last ten-sample medians were **20.4 / 28.6 MiB**. In the real-time run, first/last five-sample medians were **18.0 / 20.1 MiB**, with final RSS **20.2 MiB**. Parent CPU median during the real-time samples was **0.55%** (ps process CPU proxy); spikes occurred at processing and finalization. The parent is the headless harness, not the SwiftUI app. RSS increased during these finite runs: **there is no demonstrated all-day memory plateau or all-day resource guarantee**. Worker processes exit per job, bounding model lifetime. A multi-hour run with representative desktop workloads remains required.

### Separate operation and retention checks

| Operation | New observed measurements |
|---|---|
| Original 16 kHz mono CAF write (11.70275-second fixture) | **0.031874 s**; gzip **0.076159 / 0.076002 s** for full/tail chunks. |
| Decompression / VAD / resampling, same two chunks | **0.0716 / 0.0716 s**, **0.0202 / 0.0039 s**, **0.1332 / 0.1260 s** respectively; full audit max RSS **10,567,680 B**. |
| Upconverted original-rate 48 kHz stereo synthetic fixture | CAF write **0.158133 s**; gzip **0.068054 / 0.074992 s**; VAD **0.133606 / 0.023895 s**; resampling **0.130589 / 0.131718 s**. This is synthetic upconversion, not DJI input. |
| 100,000 expired metadata rows | Insertion **0.651861 s**; **ten indexed cleanup passes 0.001428 s total**, metadata retained with cap disabled; process max RSS **31,457,280 B**. |

VAD and level metering now inspect all input channels. Resampling explicitly requests downmixing: reducing channel count alone discarded channel 2. Unit tests preserve original 48 kHz stereo and verify right-only speech survives level/VAD and downmix. Integration also exercises a right-only 48 kHz stereo spoken fixture.

Retention fixes: an expired empty path cannot delete the data root; expired queued/writing records and their owned derivatives are cleaned; fresh tails in active sessions remain; active sessions are protected from transcript eviction. Audio expiry has an independent utility queue, and transcript-cap maintenance occurs between processing jobs, so a backlog cannot starve cleanup. Context uses the earliest source deadline; worker timeouts also respect source expiry. Runtime worker TMPDIR is a chunk-owned folder inside the excluded journal root. Startup removes crash-left SDK PCM/audio and other derivatives. Independent decompression paths and playback-generation cancellation prevent interrupted playback from resuming or overwriting processing copies.

The cap is now editable **1–10,000 MB**, default **500 MB**, or disabled to keep transcripts until manually deleted. It counts UTF-8 raw/displayed text, full decoder outputs and correction history, with oldest finalized whole-session eviction; it does not promise a hard SQLite-file-size ceiling. Normal audio expiry still runs when the cap is disabled. Cleanup is periodic, not secure SSD erasure; offline expiry still waits for startup/wake.

The final unit suite has **34 tests, zero failures, 2.38 seconds**. Native UI additionally verified restart, window-close survival, installed model indicators, saving a custom 750 MB cap and restoring 500 MB, disabling/restoring the cap, bundled synthetic import/transcription, and repeated playback/stop that remained stopped. Actual screen locking was deliberately not invoked because it would require an interactive unlock on the remote Studio and could disrupt user access; headless synthetic injection does not prove screen-lock survival. Hardware/user-required tests remain listed above.

Final integration passed with the corrected downmix: right-only 48 kHz stereo speech produced the English transcript. With a local synthetic Me profile installed, the generated overlap fixture retained text and had no Me assignments in its detected early overlap. Final logs: `reports/hardening-tests.log`, `reports/hardening-integration-final.log` (run `verify-14126275-8e88-4e54-9926-785ccb95091f`), and the two named soak folders/results/continuity records.

The attribution regression also prevents a coarse segment containing meaningful sequential speech from two people from being assigned wholly to Me; such segments remain Unknown · mixed speakers. The app now clears the queued-import banner when processing finishes.
