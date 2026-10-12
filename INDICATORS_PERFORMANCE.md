# Nagi 0.7.0 (build 14): received audio, processing and performance

Mic and System levels sit beside recording controls. Each source uses one locked mailbox slot; callbacks do not schedule a main-thread task. Changing bars are drawn in a fixed AppKit view; level publications do not invalidate the SwiftUI recording header or its separate elapsed/stage clock. The meter consumes peak RMS at at most 10 Hz, retains the last valid reading between callbacks, and reports Stopped, Waiting, Received/Quiet, or No recent frames after 1.5 seconds. Opening a view opens no audio access. Quiet frames are not evidence of DJI transmitter disconnection. Receipt meters measure incoming frames, independently of VAD saving decisions.

Timeline and Live distinguish pending finalized audio, queue work, failed ASR, failed speaker analysis, skipped digital silence and expired audio. Whisper uses completed audio chunks rather than an incremental live decoder. A chunk closes after up to 10 **saved** audio seconds or Stop; speech-only wall-clock latency may be longer. Queue seconds are source-audio duration, including both sources, not an estimated wall-clock delay. Native ASR emits model-loading/transcribing/alignment markers; the app reads a bounded log tail on its worker lane, displays elapsed stage time, and never invents completion percentages. ASR and speaker analysis stay sequential. Missing-model recovery identifies the running bundle's model location.

Settings → Performance reports main-app CPU, resident memory, transcription helper CPU, speaker-analysis helper CPU and queue/stage. 100% CPU is one core. App CPU includes UI, capture, storage and other background work; no exact UI-only or GPU attribution is claimed. Native `proc_pid_rusage` counters use the machine's Mach timebase conversion and monotonic interval deltas. PID identity changes, inaccessible counters and first samples yield Unavailable/Collecting rather than zero. Helpers register only for their process lifetime. A fixed AppKit metric view updates text without publishing one-hertz changes through the SwiftUI layout tree. Sampling stops when removed, offscreen, hidden, minimized or occluded. There is no per-second shell command.

## Validation

Generated fixtures only; no microphone/system capture or user enrollment during this validation. All existing data/settings/profile counts and fingerprints were compared read-only with the pre-change snapshot. Reports and fixture databases remain ignored by Git.

- Meter tests cover no-capture startup, silence vs absent frames, callback cadence slower than 10 Hz, separate sources, stale sessions and 100,000 callback coalescing into one publication.
- CPU tests cover identity reset, counter loss, genuine zero, independent helpers, terminated helpers, sampler stop and native counter calibration against `getrusage`.
- Native stage tests accept only known markers and exercise the real process/log polling path.
- A copy of the generated Mandarin/Japanese dual-source fixture retried all six queue jobs successfully, preserving seven transcript spans. Retry reuses existing text where present rather than forcing ASR again.
- Fresh final bundled ASR smoke tests, network denied: generated Mandarin with Whisper Medium completed in 1.163 s; generated English with Parakeet Unified completed in 1.147 s. Both returned nonempty text without errors. Actual native loading/transcribing markers were present; Parakeet also emitted alignment. These are single smoke runs, not accuracy or Mini latency benchmarks.
- Full regression suite: 143 tests, zero failures in 28.929 seconds (`reports/indicators-tests-release.log`); the final indicator/performance/stage subset also passed 13 tests. Native calibration: approximately 0.198 seconds by both `proc_pid_rusage` with Mach conversion and `getrusage`.
- 100,000 meter callback offers: approximately 23 ms wall time, two bounded slots, one publication. 1,000 native counter reads: approximately 6.6 ms wall / 6.8 ms CPU; production frequency is one read per process per second only while visible.
- Confirmed updating native performance panel, 65 seconds without AX queries: mean 1.663% of one core, median 0.163%, p95 0.280%, peak 56.485%, maximum RSS 166.8 MiB. Two adjacent brief bursts dominate the average; they are included rather than discarded. This is a process measurement, not exact sampler attribution or energy usage.
- The initial SwiftUI metric rendering averaged 22.896% after correcting its timebase. It was replaced before delivery with direct AppKit text rendering. The final steady readings are much lower; this comparison concerns the new panel implementation, not the Mini's existing post-stop behavior.

- Hidden window, 65 seconds: mean 1.530% of one core, peak 59.402%, maximum RSS 191.7 MiB. Median 0.0245%, p95 0.0514%; brief bursts remain included. This does not establish zero background work.

- Live with both native meters continuously changing at 10 Hz, no actual capture, 65 seconds: mean 2.254% of one core, median 1.353%, p95 1.789%, peak 58.833%, maximum RSS 181.3 MiB. This tests drawing/receipt instrumentation, not microphone hardware or actual capture latency. The brief peak is included.

## CPU investigation limits

The Mini was not remotely accessed or tested. Its reported main-process CPU after Stop remains unresolved without a process sample from that machine. Other apps and memory pressure may contribute to latency but do not establish why Nagi's main process consumes CPU. MainActor database reads remain a possible responsiveness risk.

An early diagnostic divided Mach ticks directly by 1e9. That was wrong on this Apple Silicon host (125/3 timebase); calibration caught it, the app and harness were corrected, and the understated percentages are invalid. Corrected copies of early reports explicitly document the unit correction. `ps %CPU` averages and short UI-automation samples are not evidence of a before/after improvement. AX tree queries themselves caused CPU bursts and were excluded from final idle measurements. The first SwiftUI meter prototype consumed approximately one full core under continuously changing synthetic levels and was replaced with native drawing before delivery. Its figure is not a valid idle baseline. An early synthetic-only 80 ms timer was removed; its workload was absent from the normal old release, so that finding cannot explain the Mini's normal-runtime report.

The old normal 0.6 release with an isolated 5,000-span fixture averaged 0.635% of one core over 65 seconds after timebase correction. A Launch Services launch stalled opening its test database; its near-zero sample is invalid as an idle UI benchmark. Direct launch completed normally. No claim of fixing all sluggishness or the Mini's 25% report is made.

## Build, run, test and profile

From the repository directory:

```sh
./scripts/build.sh
open build/Nagi.app
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift" swift test --disable-sandbox --cache-path "$PWD/.cache" -j 4
python3 scripts/profile-idle.py --pid <Nagi-PID> --seconds 65 --output /tmp/nagi-idle.json
```

For profiling, wait until the processing queue is clear, choose the view to measure, and leave the UI untouched for the full interval. CPU results include all threads in that process; helper processes are separate. RSS excludes GPU allocations and is not total machine memory pressure. No public push is part of this update.
