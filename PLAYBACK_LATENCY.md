# Conversation playback and Live latency — Nagi 0.2.1

Verified on M1 Ultra / macOS 26.6.2 with generated macOS TTS and muted synthetic playback. No microphone recording, human enrollment, private audio playback, or data upload was used.

## Continuous playback

The player follows saved audio ranges, not ASR sentence boundaries. It decompresses/prepares at most the current and next chunk on a utility queue and schedules the next AVAudioPlayer against the device audio clock. Overlapping saved ranges are trimmed. Pause/resume resets the next scheduled start. Generation tokens reject stale preparation after stop, seek or session change, and derived files are removed after use. Missing audio, gaps, length mismatches and expiry produce visible recovery messages. Sentence highlighting is a 100 ms UI clock using estimated ASR times; that clock does not control audio progression. A separate observable meter avoids invalidating the entire journal at 10 Hz.

Six muted synthetic playback tests cover continuous progression and exact end position, pause/resume, rapid start/seek/cancel, overlap trimming, missing first/next audio, gaps, expiry while paused, session switches and derived-file cleanup. These verify state and ranges, not acoustic gaplessness with a hardware loopback. Very slow disk preparation can delay a boundary; the player waits for audio rather than dropping it.

All 55 package tests passed. The six playback tests also passed in a separate profiled run (7.07 s); the sampled XCTest process peaked at 35.6 MiB RSS and averaged 4.83% CPU of one core across 39 samples. This includes fixture generation, gzip and XCTest overhead, excludes SwiftUI/CoreAudio daemon costs, and is a small test measurement rather than an energy claim. Native synthetic UI inspection confirmed Play, Pause/Resume, timestamp restart, the highlighted row at the paused position, tab transitions and both mode choices. Synthetic app playback is automatically muted; recording/enrollment controls stayed disabled.

## Event-driven Live updates

The persistent worker emits bounded NDJSON snapshots. Foundation's asynchronous pipe reader persists each snapshot, then dispatches a notification to the main queue. SwiftUI reloads its bounded 200-paragraph window on that notification; the former 1-second view polling timer was removed. Final archival processing sends its own change notification. Worker identity checks reject delayed UI callbacks from an old session. EOF drains final snapshots before releasing the ML lease. SwiftUI can combine changes within a render pass; no extra debounce delays final text. There are no new repeating observers or redraw timers in this path. Existing status/retention/watchdog timers serve their separate purposes.

The pinned engine supports Balanced L=5,600/C=560/R=560 ms versus model-default Accuracy L=5,600/C=1,040/R=1,040 ms. The model still waits for sufficient audio/right context. Balanced is now the preview default; Accuracy remains selectable before recording. This setting does not change final archival ASR/alignment or speaker analysis.

## Timestamped production-path comparison

`python3 scripts/latency.py` generates 12 distinct marker phrases alternating installed Samantha/Daniel voices, trims amplitude silence with 20 ms padding, inserts 400 ms silence, then feeds original buffers at real time through the production ChunkWriter, warm-up pre-roll, LiveTranscriber and archive/final-processing paths. No capture device is opened. Both runs preserve every archived Float32 sample. Phrase-end timestamps are an amplitude-derived proxy for marker completion, not forced phonetic alignment. Eleven markers after the first define the steady distribution; the first is excluded for model warm-up. The 21.28-second fixture is small and clean, not evidence of general recognition accuracy.

| Metric | Accuracy | Balanced |
| --- | ---: | ---: |
| First nonempty callback from capture start | 2.080 s | 1.655 s |
| Steady marker lag p50 | 1.486 s | 0.816 s |
| Steady marker lag p90 | 1.854 s | 0.959 s |
| Steady marker lag maximum | 1.855 s | 0.968 s |
| Recognized markers | 12/12 | 12/12 |
| Final preview WER against fixture text | 0% | 0% |
| Disappearing-word revision proxy | 0 | 2 |
| Snapshot count | 20 | 36 |
| Active sampled CPU, % of one core | 2.44% | 3.13% |
| Peak harness + Live worker RSS | 884.8 MiB | 888.3 MiB |

Latency ends at the production callback, not at physical screen presentation. Removing the old UI timer removes its possible 0–1 second wait; actual screen-paint latency was not instrumented. CPU/RSS use `ps` at approximately 250 ms intervals; active CPU excludes the first 2 seconds and post-stop processing, RSS includes warm-up. GPU/ANE power and competing workloads were not measured. The revision proxy counts unique words disappearing from a previously exposed hypothesis; it is not an edit-distance stability benchmark. Balanced improves this fixture's callback latency with slightly more updates/CPU and temporary revisions. Both modes still run final archival processing sequentially after Live exits; long sessions accumulate visible deferred final jobs.

Raw local evidence: `reports/latency-ea794ff4-566c-424b-b764-d5a558a3c27f/{truth.json,summary.json,accuracy.log,balanced.log,*-samples.json}`. Reports, generated audio and journal databases are ignored and never pushed. Previous five-minute and crash/resource evidence remains in [LIVE_VERIFICATION.md](LIVE_VERIFICATION.md); those baseline measurements used the older default context.

New Balanced recovery checks: a 35-second production fixture with worker SIGKILL at 12 seconds passed exact sample continuity and final processing (41.26 s total, 893.5 MiB peak family RSS). A 60-second fixture offered at 50× speed also passed archival continuity despite preview overload (18.22 s total, 892.5 MiB peak family RSS). These deliberately artificial runs include post-stop ML; their CPU/latency values are not normal recording estimates. Evidence is in `reports/live-profile-live-f4c83566-ebfd-432e-ae9a-7781e8d3a7ee`, `reports/live-profile-live-4515d80a-6081-4af3-a51a-85cca62257df`, `reports/final-playback-tests.log` and `reports/playback-profile.json`.

Real receiver unplug/TX loss, real-speaker accuracy, actual microphone permission/capture, screen lock/sleep with hardware, multi-hour Balanced operation, audio-device output interruptions and competing-workload performance remain untested. The app does not claim transmitter loss from silence or universal subsecond latency.
