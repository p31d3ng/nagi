# Nagi

A native SwiftUI voice journal for macOS. Nagi (凪) means calm or a lull in the wind. This is a working Stage 1 prerelease: all capture, audio, models, transcription, speaker analysis and search stay on the Mac. No cloud endpoint or telemetry is implemented.

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

On the original Studio, the complete project is `/Users/pei.deng/Documents/Codex/2026-10-10/task/Nagi`, and the app is `build/Nagi.app`. Local journal state is in `~/Library/Application Support/Nagi`; override `STILLPOINT_DATA` to use a separate test data folder and `STILLPOINT_PROJECT` to override the project path. These legacy environment keys remain supported internally.

Choose your receiver in **Devices**, save settings, and explicitly press **Start recording**. macOS microphone permission is requested only then. Closing the window leaves the menu-bar app alive; use its Open journal action to return. Quit stops and finalizes capture. Locking the screen does not intentionally stop capture. System sleep finalizes and marks a gap; recording must be restarted after wake. Optional idle-sleep prevention applies only while recording.

Use **Import audio** to test with files without opening a microphone. Imported audio expiry starts at import time, since the original capture time is unknown. Generated fixtures and demo sessions are explicitly synthetic.

## Local behavior

- Input selection persists the Core Audio device UID. No default-device fallback. Every captured buffer verifies the bound AudioUnit's device ID; a change/disappearance drops that buffer and stops capture. Device reconnection prompts for an explicit start. RX unplug and TX radio loss are different; digital silence cannot establish transmitter disconnection.
- Continuous original-rate/channel Float32 CAF audio is sealed about every 10 seconds. Gzip preserves the CAF bytes exactly. Compression and ML run outside capture; at most 64 copied input buffers may await disk writing. Storage overload produces a visible stop/gap.
- SQLite WAL, FULL synchronization, durable chunk states and a serial worker queue. Crashed processing jobs return to queued. Completed CAF chunks and readable open CAF tails recover on startup. The final tail can still be incomplete after an abrupt crash; recovery reports that honestly.
- Exact **Parakeet Unified EN 0.6B Q8_0**, not TDT v3. Streaming API feeds use 320 ms blocks. Because the current upstream streaming API lacks word timing, a sequential offline pass supplies word alignment. Both raw streaming and aligned outputs are retained in SQLite. Timeline updates arrive after each durable chunk, not instant microphone token updates. The adapter uses the pinned public C API in a separate process; experimental Swift bindings were inspected but are not relied upon.
- Selectable **Whisper Medium Q4_K_M** for Mandarin/Japanese and other languages. Switching is manual between sessions. Engine detected language is retained in `asr_runs`; UI tags deliberately use conservative script estimates/model assumptions and flag mixed/uncertain text.
- Community-1 offline diarization runs after ASR in a separate process. Voice enrollment uses the same 256-dimensional Community-1 embeddings as conversation matching, never legacy SpeakerManager embeddings. Conservative similarity/margin thresholds can return Unknown. Labels are editable. Count is an estimate. Overlap/distant speech and short chunks remain limitations; see `VERIFICATION.md`.
- Preferred words are review hints. Exact case-sensitive replacement rules operate after ASR, with original and correction history retained and Undo available. Fuzzy correction/decode-time bias is not claimed.
- Near digital silence skips ASR via an RMS threshold; continuous audio is preserved. Low noise can still reach ASR and hallucinate; noise fixtures are part of validation.
- Audio expires 48 hours from each chunk's capture (or import) timestamp, including derived copies. Startup, wake and a minute maintenance tick remove expired audio. Playback is prohibited immediately after expiry. While the app/Mac is off, deletion cannot execute; the UI says so. The data directory is marked excluded from backup where supported. This is not secure erasure of SSD snapshots.
- Transcripts persist until deletion or the optional 500 MB UTF-8 text/history cap. The cap evicts oldest finalized whole sessions and their audio; active capture is protected. SQLite/index/metadata overhead is separate. Recent sessions are bounded to 500; keyword search returns at most 2,000 rows per query. CJK queries use exact substring matching so short Mandarin/Japanese words remain searchable.
- Worker processes have networking denied and 180-second timeouts. Missing/corrupt models and speaker-analysis failures are recoverable through Retry. Speaker retries preserve raw/corrected text and correction history. There is no automatic cloud fallback.

## Test

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift" \
swift test --disable-sandbox --scratch-path .build --cache-path .cache -j 4
python3 scripts/fixtures.py
python3 scripts/verify.py
# Optional full ten-minute synthetic processing stress run:
python3 scripts/verify.py --stress
```

macOS TTS and Metal/Core ML need normal host access; restricted execution sandboxes may generate empty TTS files or deny compiler caches. The app does not request global security changes. `VERIFICATION.md` records measured results and remaining hardware/real-speaker gaps.

## Architecture and future work

`JournalCore` owns storage, original-rate capture, compression, recovery and processing. `Native/ASRWorker.cpp` owns bounded ASR jobs. `SpeakerWorker` owns Community-1 inference. SwiftUI owns status/timeline, device/model/profile/dictionary/storage settings, search, review and playback. `SessionExporter` is the clean future Stage 2 boundary; no upload implementation exists.

Stage 2 remains future work: configurable HTTPS endpoint, R2 retention, Workers AI summaries, D1 metadata, Keychain credentials and a durable upload retry queue. Nothing is deployed.
