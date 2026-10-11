# Speech-only saving — Nagi 0.3.0

## Behavior

**Storage → Saving for new recordings** defaults to **Speech only**. **Continuous audio** preserves every sound. The setting cannot change during recording, and old recordings are untouched. Guided voice enrollment and file imports remain continuous; enrollment still validates clear voice and sufficient usable audio before saving a profile. No microphone is opened automatically.

Speech-only uses pinned Silero VAD v6.2 F32, CPU backend only, one thread. It scores 32 ms frames with start/continue probabilities 0.35/0.20. It has no minimum utterance duration and no transcript/semantic filter. One second of original-rate/channel pre-roll and one second of hangover protect beginnings, endings and short interjections (timing is quantized to roughly 32 ms). The strongest input channel is used for detection so opposite-polarity channels cannot cancel; every channel is saved unchanged. A small linearly resampled mono copy is used only for detection. The microphone callback retains its nonblocking bounded admission queue; detection and saving happen on the writer lane, independently of ASR/diarization. Pre-roll is bounded to about one second plus a partial frame, with supported input limits of Float32, 8–192 kHz, and at most 16 channels. Unsupported formats or model failures stop with recovery guidance; saving mode never silently changes.

No audio file is created until speech is detected. Kept spans use ordinary original-rate CAF/gzip chunks, fsync, SQLite durable processing and the existing 48-hour retention. Captured-frame progress still includes omitted input, so silent input is not confused with a disconnected microphone. UI distinguishes **Listening** from **Saving speech + short buffers**. A silent session reports no saved audio. Speech remains saved if ASR fails, produces empty text, or uses an unsuitable language model. Loud noise can cause false positives, and very faint/distant/atypical speech can cause false negatives; Continuous is the preservation option. This is not a guarantee that every sound is semantically meaningful.

## Original time and recovery

Chunk offsets are original elapsed capture time, and `captured = session start + offset`; time is never compressed invisibly. `audio_gaps` records explicitly omitted non-speech intervals, updated durably about once per second during long omissions. `capture_progress` tracks input progress for recovery. Crash-left open CAF tails use existing recovery; uncertain unfinalized intervals are marked `crash_unfinalized`, rather than asserted to be silence. Up to the in-memory pre-roll/partial frame and progress checkpoint can be lost in an abrupt crash. The interrupted-session notice remains explicit.

ASR context never crosses a time gap. A finalized speech span can enter batch processing after its omission boundary is known, without waiting for another spoken chunk. Live receives only kept spans, retains original offsets, and gets an explicit end-of-span IPC event after post-roll. Its persistent worker finalizes promptly and resets its stream across gaps; ASR is not fed synthetic concatenated time. End events share the bounded warm-up/feed queue. A long silence no longer triggers the progress watchdog. Worker failure returns to the durable archive; final ASR and diarization remain sequential.

Playback automatically skips only gaps documented as omitted non-speech, displays the amount skipped, and jumps its clock/highlight to the original elapsed position. Missing files, expiry and capture-error gaps still stop with a recovery message. Search and speaker/language timestamps stay on that same elapsed timeline.

## Verified synthetic results

61 package tests pass, including exact original sample/rate/channel preservation, bounded pre-roll, short/partial speech, gap mapping, idempotent stop, detector-failure sealing, crash recovery and playback skip behavior. The actual Silero integration uses only generated macOS TTS and deterministic noise; no ambient microphone, private recording or human enrollment is used.

| Fixture | Result |
| --- | --- |
| 30 s silence, white noise, or 35 Hz wind proxy | Zero audio files / zero audio bytes |
| English with 20 s digital silence around it | 31.70 → 13.73 saved seconds; 4 → 2 files; 449,940 → 443,879 gzip bytes |
| Same speech surrounded by Gaussian background noise | 31.70 → 13.79 saved seconds; 1,225,491 → 524,600 gzip bytes (57.2% fewer) |
| English at 2% amplitude, Mandarin, Japanese | First-to-last fixture speech covered; every kept original sample exact |
| 0.31 s “Oh!” | Audio retained with buffers (2.37 s); ASR recognition is not a saving requirement |
| Right-channel-only stereo | Speech retained; both original channels exact |
| Live with 50 s omitted pause | Original-time spans, no false stalled-worker failure, exact kept audio |
| Abrupt whole-harness exit during speech | Recovered a 4.096 s queued CAF tail; interrupted session retained |
| Live worker killed 2 s into speech | Every archived sample intact; both chunks subsequently completed final ASR/diarization |
| 30 min synthetic silence offered as fast as possible | Zero audio files; ~1 s bounded pre-roll |

Digital zeros compress very well already: this fixture saved about 57% of audio duration but only 1.35% of gzip bytes. File-count reduction and real background-noise byte savings are different measures. Tiny pre/post-roll spans include some non-speech by design.

## Resources and reproduction

The final English write/VAD run used 0.0110 wall seconds per audio second versus 0.00286 for Continuous; stereo used 0.0153. This includes saving and SQLite progress writes, excludes model startup, gzip verification/compression and final ML. Sampled harness peak RSS was about 25.3 MiB with VAD versus 14.5 MiB continuous. The 30-minute stress processed in 18.12 s, peaked at 24.0 MiB harness RSS, and retained at most 16,384 mono frames. The paced 82.70-second Live run completed in 82.77 s and retained 28.83 s of audio, with 26.1 MiB harness peak RSS. `ps` samples at ~100 ms intervals are CPU/RSS proxies, not watts or GPU energy; fast stress-test CPU approaches one core because it intentionally runs ~100× real time. Live process RSS samples here exclude its separate ~0.9 GiB ASR worker. No new claim of reduced ASR model memory is made. Buffers are bounded; these finite tests do not prove multi-day resource behavior.

Final integration evidence is in `reports/speech-saving-7b2a3548-99f8-4d37-b866-c2d9f61d3329/{summary.json,*-samples.json,*.log}`, `reports/speech-tests.log`, `reports/speech-fallback.log`, and `reports/speech-fallback-final.log`. A separate final English pipeline check completed both chunks in 5.45 s, retained the first/last fixture words, and returned timestamped keyword search results on the original 12.53–23.70 s speech interval. Recognition still has ordinary model errors; the archive audit proves audio retention, not recognition accuracy.

```sh
./scripts/install-models.sh  # explicit setup; includes checksum-pinned Silero weights
./scripts/build.sh
swift test --disable-sandbox --scratch-path .build --cache-path .cache -j 4
python3 scripts/speech-saving.py
.build/debug/JournalHarness speechgate reports/new-fallbackData Fixtures/english.wav "$PWD" speechOnly live -1 2
.build/debug/JournalHarness process reports/new-fallbackData "$PWD"
```

Reports, generated fixtures, model weights and journal databases are ignored and excluded from the source push. Exact dependency revision/checksum and separate model terms are recorded in `DEPENDENCIES.json` / `THIRD_PARTY_NOTICES.md`. Actual wearable hardware, real wind/noise/music, overlapping/distant voices, microphone permissions, and manual UI/capture flows remain untested. No new test app identity or privacy-permission workaround was used for this change.

The native Storage screen was inspected using the same main bundle with `NAGI_SYNTHETIC_MONITOR=1` and an isolated synthetic data directory: the Speech-only default and explanatory setting were present, microphone/settings mutation controls were disabled, and muted playback displayed “Skipped 11.0 seconds” and began its clock at 00:11. The monitor was then closed and the normal journal restored. No private audio was played or enrollment started.
