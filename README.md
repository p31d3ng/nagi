# Nagi

A native SwiftUI voice journal for macOS. Nagi (凪) means calm or a lull in the wind. Capture, audio, models, transcription, speaker analysis and search stay on the Mac. Nagi 0.4.0 adds optional transcript-only summarization: configure an HTTPS service and app bearer in Settings, then submit a saved conversation manually or opt in for new recordings. Automatic sharing is off by default. Audio and voice profiles never upload; no telemetry is implemented.

Nagi 0.7.0 adds independent received-audio meters beside recording controls, clearer finalized-chunk/queue/error indicators, and Settings → Performance with native process CPU/RSS readings. See [indicator and performance validation](INDICATORS_PERFORMANCE.md). The Mini-specific post-stop CPU report remains unresolved; Studio results are not a claim of fixing that machine.

## Build and run

Requirements: Apple Silicon Mac, macOS 15+, Xcode with Swift 6.2+, CMake, Python 3. The verified machine is an M1 Ultra Mac Studio with 128 GB RAM, macOS 26.6.2, Swift 6.3.3. Dependencies are pinned in `DEPENDENCIES.json`. No developer account or signing identity is needed for the local ad-hoc build.

```sh
./scripts/bootstrap.sh
./scripts/build.sh
# Explicit optional setup downloads ~1.2 GB ASR weights plus diarization assets.
# Read THIRD_PARTY_NOTICES.md and model cards first.
./scripts/install-models.sh
open build/Nagi.app
```

Source dependencies live in the sibling `../Dependencies` directory. Bootstrap refuses to overwrite a different existing checkout. Build uses workspace caches and four compiler jobs. The generated app bundles runtime helpers and any installed models. After model installation, the setup script rebuilds the local app. App bundles and weights remain Git-ignored; no model weights are pushed to the source repository.

On the original Studio, the complete project is `/Users/pei.deng/Documents/Codex/2026-10-10/task/Nagi`, and the app is `build/Nagi.app`. Local journal state is in `~/Library/Application Support/Nagi`; override `NAGI_DATA` to use a separate test data folder and `NAGI_PROJECT` to override the project path. The default journal location and saved settings are unchanged; development overrides use the NAGI-prefixed environment keys.

Choose your receiver in **Settings → Devices**, save settings, and explicitly press **Start recording**. Microphone access is requested only through explicit Start/Enroll or Settings → Permissions actions. Closing the window leaves the menu-bar app alive; use its Open journal action to return. Quit stops and finalizes capture. Locking the screen does not intentionally stop capture. System sleep finalizes and marks a gap; recording must be restarted after wake. Optional idle-sleep prevention applies only while recording.

Use **Import audio** to test with files without opening a microphone. Imported audio expiry starts at import time, since the original capture time is unknown. Generated fixtures and demo sessions are explicitly synthetic.

## Local behavior

- Input selection persists the Core Audio device UID. No default-device fallback. Every captured buffer verifies the bound AudioUnit's device ID; a change/disappearance drops that buffer and stops capture. Device reconnection prompts for an explicit start. RX unplug and TX radio loss are different; digital silence cannot establish transmitter disconnection.
- New recordings default to speech-only saving with bounded pre/post-roll and explicit elapsed-time gaps. Continuous is selectable; enrollment/imports stay continuous. Kept original-rate/channel Float32 CAF audio is sealed at exact ten-second frame boundaries, with shorter span-end/final/recovered tails. Gzip preserves CAF bytes exactly. Compression and ASR/diarization run outside capture; at most 64 copied input buffers may await the writer. Storage overload produces a visible stop/gap.
- SQLite WAL, FULL synchronization, durable chunk states and a serial worker queue. Crashed processing jobs return to queued. Completed CAF chunks and readable open CAF tails recover on startup. The final tail can still be incomplete after an abrupt crash; recovery reports that honestly.
- Exact **Parakeet Unified EN 0.6B Q8_0**, not TDT v3. Streaming API feeds use 320 ms blocks. Because the current upstream streaming API lacks word timing, a sequential offline pass supplies word alignment. Both raw streaming and aligned outputs are retained in SQLite. Timeline updates arrive after each durable chunk, not instant microphone token updates. The adapter uses the pinned public C API in a separate process; experimental Swift bindings were inspected but are not relied upon.
- Selectable **Whisper Medium Q4_K_M** for Mandarin/Japanese and other languages. Switching is manual between sessions. Engine detected language is retained in `asr_runs`; UI tags deliberately use conservative script estimates/model assumptions and flag mixed/uncertain text.
- Community-1 offline diarization runs after ASR in a separate process. Voice enrollment uses the same 256-dimensional Community-1 embeddings as conversation matching, never legacy SpeakerManager embeddings. Conservative similarity/margin thresholds can return Unknown. Labels are editable. Count is an estimate. Overlap/distant speech and short chunks remain limitations; see `VERIFICATION.md`.
- Preferred words are review hints. Exact case-sensitive replacement rules operate after ASR, with original and correction history retained and Undo available. Fuzzy correction/decode-time bias is not claimed.
- Speech-only uses Silero VAD before saving; it never decides retention from transcript text. Continuous audio remains preserved, including silence. Near digital silence in retained/imported audio can skip ASR via a conservative RMS threshold. Noise can still trigger saving or ASR hallucinations; synthetic noise fixtures are part of validation.
- Audio expires 48 hours from each chunk's capture (or import) timestamp, including derived copies. Startup, wake and a minute maintenance tick remove expired audio. Playback is prohibited immediately after expiry. While the app/Mac is off, deletion cannot execute; the UI says so. The data directory is marked excluded from backup where supported. This is not secure erasure of SSD snapshots.
- Transcripts persist until deletion or the optional configurable UTF-8 text/history cap (default 500 MB). The cap evicts oldest finalized whole sessions and their audio; active capture is protected. SQLite/index/metadata overhead is separate. Recent sessions are bounded to 500; keyword search returns at most 2,000 rows per query. CJK queries use exact substring matching so short Mandarin/Japanese words remain searchable.
- Worker processes have networking denied and 180-second timeouts. Missing/corrupt models and speaker-analysis failures are recoverable through Retry. Speaker retries preserve raw/corrected text and correction history. There is no automatic cloud fallback.

## Test

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift" \
swift test --disable-sandbox --scratch-path .build --cache-path .cache -j 4
python3 scripts/fixtures.py
python3 scripts/verify.py
python3 scripts/boundary.py
# Production enqueue + write + sequential ML; synthetic input, never a microphone:
python3 scripts/soak.py 1800 4
python3 scripts/soak.py 300 1
# Verify all archived samples against the generated source:
python3 scripts/check-soak-audio.py reports/soak-<run-id>/Data
# Optional full ten-minute synthetic processing stress run:
python3 scripts/verify.py --stress
```

macOS TTS and Metal/Core ML need normal host access; restricted execution sandboxes may generate empty TTS files or deny compiler caches. The app does not request global security changes. `VERIFICATION.md` records measured results and remaining hardware/real-speaker gaps.

## Live transcript

Nagi 0.3.0 defaults new recordings to **Speech only** saving. Change it in **Settings → Storage → Saving for new recordings**. A local CPU speech detector keeps short pre/post buffers and records omitted intervals on the original timeline. Existing audio is unchanged; enrollment/imports stay continuous. Playback skips documented non-speech while reporting the time jump. See [speech saving verification](SPEECH_SAVING.md) for behavior, measurements and limitations.

Nagi 0.2.1 uses worker output callbacks for partial/final text and processing notifications for final transcript changes. The Live view has no text polling timer. Choose **Balanced · quicker** (default, 560 ms chunk + 560 ms right context) or **Accuracy · more context** (1,040 ms each) before recording. Model look-ahead still causes recognition latency; final archival decoding is unchanged. See [playback and latency verification](PLAYBACK_LATENCY.md) for the measured comparison and limitations.

Open **Live**, select the English Unified model/input, then explicitly press **Start recording**. Opening the tab never starts a microphone. The rounded transcript panel updates as the model receives audio; tentative words are shown dimmer when the engine's stable-prefix view agrees with its current hypothesis. Scroll up to pause following and use **Jump to live** to return. Text is selectable and **Copy shown text** copies the current window. The view renders at most 200 paragraphs; **Earlier text** pages through the conversation without retaining an ever-growing UI history. Timeline search remains available for final transcripts.

Audio capture, original-rate CAF sealing and lossless compression continue independently. One persistent, network-denied English worker keeps its model loaded and accepts a bounded queue of post-write buffers. Preview hypotheses use bounded 30-second windows. Their text is provisional; window boundaries and recognizer revisions can change it. Final archival alignment and Community-1 speaker analysis wait until the live worker releases its model. The number of chunks awaiting final processing is visible. A long live session can therefore take additional time to finish speaker labels after Stop. The final pipeline replaces previews by complete audio ranges and preserves edits/raw versions; it does not concatenate preview text into the final transcript.

Once activated during a recording, preview keeps running across tab switches/window closure. A new recording started outside Live uses the ordinary chunk pipeline. Stop releases the live worker before final ML runs. Worker failure/overload returns to chunk processing; audio capture remains independent. **Resume live preview** retries during an ongoing recording. Multilingual Whisper currently shows completed chunk updates, with no incremental-preview claim. There is no subsecond-latency guarantee; see `LIVE_VERIFICATION.md` for measured synthetic results and resource limits.

Voice enrollment now saves a profile only after the complete sample has passed checks. It combines consistent Community-1 embeddings from usable chunks, ignores tiny stop tails, and preserves a previous profile on failure. No-frame capture is stopped visibly after roughly five seconds. Watch input levels during enrollment and wait for **Local voice profile saved successfully**; a finished recording alone is not a saved profile.

## Source formatting

Swift, C++ and Python sources use checked-in formatter settings. Keep source readable with normal indentation and statement blocks. From the project root:

```sh
xcrun swift-format format -i -r Sources Tests Package.swift
xcrun clang-format -i Native/*.cpp Sources/CSQLite/shim.h
# Optional development formatter, installed in your own Python virtual environment:
python -m black scripts
```

The verified formatter versions are Xcode swift-format 6.3.0, Xcode clang-format, and Black 26.10.1. Formatters are development tools; the app does not depend on Python formatter packages.

## Architecture and future work

`JournalCore` owns storage, original-rate capture, compression, recovery and processing. `Native/ASRWorker.cpp` owns bounded ASR jobs. `SpeakerWorker` owns Community-1 inference. SwiftUI owns status/timeline, device/model/profile/dictionary/storage settings, search, review and playback. `SummaryStorage` creates checked finalized transcript snapshots; `SummaryController` owns explicit consent, durable claims and local response history; `SummaryHTTPTransport` is the bounded optional HTTPS client. The older `SessionExporter` remains a future audio-sync boundary.

### Conversation playback

Select a conversation in Timeline and press **Play conversation**. Playback continues automatically across recorded chunks; use **Pause**, **Resume**, or **Stop**. Clicking a transcript timestamp starts continuous playback from that point. The current sentence highlights using its estimated transcript times. Selecting another conversation stops playback. Missing/expired audio or a recording gap stops playback with an explanation; you can choose a later available timestamp explicitly. Playback is disabled during recording. Audio availability remains subject to the 48-hour expiry.

Optional transcript-only summarization and Keychain settings are implemented in 0.4.0. See [setup and verification](SUMMARY_INTEGRATION.md). Audio sync, R2 retention, D1 metadata and phone access remain future work. Backend implementation and infrastructure are managed separately in a private repository; this app repository contains only the client contract and synthetic tests.

## Hardening behavior

Unified EN uses the requested streaming decoder as the canonical transcript. A separate offline pass estimates word times; exact-token alignment preserves the streaming words, and both raw outputs are retained. Each exact ten-second archive chunk gets up to 0.75 seconds of neighboring ASR context on each side; timestamp midpoint ownership selects displayed words without deleting legitimate repetitions by text. During recording this waits for the next sealed chunk, so updates can take about twenty seconds plus processing. Whisper keeps segment timing and currently does not use this word-context strategy. Recognition and timing errors remain possible.

Community-1 emits nonexclusive turns. A separate bounded pass of the same pinned segmentation model retains pre-clustering powerset overlap hints, including when clustering collapses two voices into one identity. Hinted spans receive Unknown labels, overriding Me. This is an uncertainty detector, not source separation or a guaranteed speaker count; it may miss overlaps or flag solo speech incorrectly.

Audio expiry runs on an independent queue while ML is busy. Derived audio has chunk ownership; context copies use the earliest source deadline. Worker TMPDIR is inside the journal, and startup removes crash-left temporary audio. Decompression consumers use separate files. Playback checks expiry and cancels interrupted preparation. Metadata retention uses indexed, bounded batches; expired empty paths can never be interpreted as the data root. All input channels contribute to level/VAD measurements, and ASR resampling explicitly enables downmixing.

The transcript cap accepts 1–10,000 MB (default 500); turning it off keeps transcripts until deletion while audio still expires after 48 hours. See VERIFICATION.md for the 30-minute accelerated soak, real-time soak, boundary regressions, overlap failure/uncertainty handling and the subsequent two-hour results in MEMORY_PROFILE.md and remaining full-day/hardware tests.


## Independent synthetic test mode

Normal use: `scripts/run-normal.sh` launches a new normal Nagi instance, even if a test is running. It clears synthetic/data/project environment overrides and uses `~/Library/Application Support/Nagi`. Choose and start your microphone explicitly. Avoid launching multiple normal instances against one journal simultaneously.

`python3 scripts/memory-soak.py 7200 120` runs two hours of generated speech at real-time pace with two-minute idle controls before/after. It creates a distinct **Nagi Synthetic Test** bundle and isolated journal under `reports/`, uses the production enqueue/write/ASR/diarization paths, and observes the timeline in SwiftUI with 12.5 meter updates per second. No microphone or voice enrollment opens. The orange banner and test window title distinguish this from normal Nagi; recording/import/settings controls are disabled. An older test window may display “This synthetic monitor never opens a microphone” if Start is pressed: that is a test guard, not a microphone permission error.

The controller samples process RSS/CPU, queue counts and storage, saves bounded periodic native heap/vmmap/leaks summaries, and caps journal test data at 2 GiB. Test bundles use APFS copy-on-write clones of the local app and remain Git-ignored. Idle system sleep is prevented only while the synthetic producer runs; screen lock is untouched. Native profiling may need host tool access. `python3 scripts/analyze-memory.py reports/memory-soak-<run-id>` generates local trend summaries. Raw reports, model weights, audio, transcripts and speaker embeddings are never committed.

The v0.1.2 investigation and verified two-hour results are in [MEMORY_PROFILE.md](MEMORY_PROFILE.md). Timeline indexes avoid sorting an entire large conversation to display the bounded 2,000-row result.

For a generated 100,000-row UI capacity control without microphone or ML: `python3 scripts/ui-memory.py 100000 300`. Test bundles retain their mode and isolated data path in Info.plist when reopened.

## Microphone permission check

Nagi 0.4.1 adds **Settings → Permissions** with the actual macOS microphone status, an explicit first-access request, read-only refresh on activation, and recovery instructions. Device connection is shown separately. See [permission behavior and repeated-prompt investigation](PERMISSIONS.md). Development builds remain ad-hoc signed; this UI does not guarantee permission persistence across rebuilds.

## Unified Settings and visible version

In 0.4.2, **Settings** contains Permissions, Summarization, Devices, Models, Storage, Voice profile and Dictionary. The sidebar is Timeline / Live / Settings. Version appears in the sidebar; version and build details appear in Settings, read from the installed bundle. See [navigation and verification](SETTINGS.md).

## Rebuild/install and quick input

Quit Nagi, then run `./scripts/rebuild-install.sh` to rebuild and install `/Applications/Nagi.app`. The script refuses a running app, stages/verifies the complete bundle, keeps a recoverable previous copy, and never launches or changes user data. See [installation, permissions and tests](INSTALL.md).

Nagi 0.4.3 adds the input picker beside Start recording, synchronized with Settings → Devices. Settings uses the available pane width, and the Live empty state is centered. See [behavior and verification](QUICK_INPUT_LAYOUT.md).

## Navigation clicks

Nagi 0.4.4 makes the full navigation row clickable, including trailing whitespace, and explicitly allows activation clicks on navigation buttons. Live-page database reads run off the main actor with bounded coalescing. See [evidence and limits](NAVIGATION.md).

Optional system audio (0.5.0): enable it in Settings → Devices, grant access explicitly, and start with your selected microphone. Sources stay separate through recording, transcription and playback. See [SYSTEM_AUDIO.md](SYSTEM_AUDIO.md) for behavior, synthetic tests, resource measurements and untested hardware limits.

In 0.6.0, the existing Storage saving preference applies independently to microphone and system audio on new recordings. Continuous remains selectable. See [DUAL_SPEECH_ONLY.md](DUAL_SPEECH_ONLY.md) for timestamp/recovery behavior, tests and measured savings.
