# Independent dual-source speech-only saving — Nagi 0.6.0, build 13

**Settings → Storage → Saving for new recordings** now applies independently to
microphone and system audio. The existing saved preference is respected; no setting
is reset during upgrade. It is snapshotted before startup, cannot be changed while
starting/recording, and never rewrites old audio. Continuous remains available.
Enrollment and imports stay continuous. There is no real capture or public push in
this implementation's automated validation.

Each source owns its detector state and writer. Every input channel has its own
Silero 6.2 recurrent state (CPU only, one thread per inference). If any channel
passes the gate, every original channel is retained; a loud music/noise channel
cannot win an energy comparison and suppress detection on the quieter channel.
The gate uses 32 ms detector windows, a 0.35 start threshold, a 0.20 continuation
threshold, approximately one second of pre-roll and one second of post-roll. Only
the detector copy is resampled to 16 kHz; saved Float32 CAF/gzip retains original
rate, channels and samples. Simultaneous speech can open both gates independently.
This is speech presence detection, not diarization, identity, or echo cancellation.

Kept blocks use their original source-buffer timestamps, including partial blocks
across buffer boundaries. Ordinary gradual clock drift does not accumulate from a
session-wide frame counter or generate false gaps. A discontinuity/clock-quality
change finalizes the old epoch, flushes its pending block, closes its file and resets
that source's recurrent state before the next epoch. Omitted intervals do not
collapse session time. Clock fallback remains explicitly uncertain; missing input,
clock adjustments and failures are distinct from intentionally omitted non-speech.

The additive source_progress table records processed capture progress separately
for each session/source. Source omissions use source_gaps with origin in its primary
key. Playback skips only omissions on its selected source; another source's silence
cannot authorize skipping a hardware gap. ASR lookahead release and audio context
also stay source-specific. Legacy omission/progress tables remain readable for old
single-source journals. On crash, durable chunks are recovered and known unfinished
tails are marked crash_unfinalized, not silence. Uncheckpointed/queued/in-memory
pre-roll audio can be lost; its exact final endpoint cannot be reconstructed after
process death. No synthetic silence is invented to fill it.

Possible-echo analysis remains evidence only. It examines bounded overlapping
retained host-clock spans, never concatenates across omitted intervals, and checks
up to 16 peers in a bounded time range for small speech spans. A missing/short/expired
reference produces no evidence; it does not prove there was no echo. All text/audio
is preserved, with reversible hints. Source and echo fields remain local: the
optional summary backend still receives its established text/speaker/timestamp
schema, and may receive duplicated speech when the user has enabled sharing.
No new consent, automatic upload, endpoint, credentials or backend change is added.

VAD can miss faint, distant or very short speech and can keep noise or music. Choose
Continuous when preserving every sound matters. Synthetic faint/brief speech was
retained in the fixture below, but procedural music also caused a false-positive
saved interval. Those results do not establish real-room or real-music accuracy.
Omitted audio cannot be restored by transcript Undo. The same 48-hour audio/derived
expiry, backup exclusion, transcript cap and local voice profile policies remain.

## Validation

The final applicable suite passed 130 tests, zero failures in 28.032 seconds,
including the playback wording clarification. New cases cover independent gates,
overlap, a louder non-speech stereo channel beside weaker speech, exact original
samples/offsets, gradual drift, clock discontinuities/quality changes, invalid
probabilities, detector failure, sealed earlier speech, per-source progress/recovery,
legacy behavior, source-only lookahead without loading ML, playback omission versus
another source's gap, missing echo reference, original-timestamp expiry and native
recurrent-state reset, including both public VAD convenience constructors across
epoch/timestamp boundaries. Existing cancellation/error-provenance and zero-upload fake
transport tests also pass. Full output remains in ignored reports/.

An abrupt isolated dual-gate harness exit (75) at 20 seconds recovered three chunks:
microphone 6.016–16.016 and 16.016–17.600, system 8.992–18.720. Separate durable
progress was 19.456 seconds per source. Microphone 18.624–19.456 and system
18.720–19.456 were explicitly unknown crash tails. No writing chunks remained after
recovery. This exercises generated file injection, not physical receiver failure.

All retained PCM from four actual-detector synthetic datasets was decompressed,
converted back to PCM and compared byte-for-byte with its original source at its
saved offset; every comparison passed. Each dataset was 45 seconds per source,
48 kHz microphone mono plus system stereo. Fixtures used installed Samantha/Daniel,
Tingting and Kyoko voices, silence, seeded noise, attenuated speech, a 280 ms utterance
excerpt and procedural instrumental-like chords. The chord proxy is not a real-music
accuracy benchmark. Fixtures and raw profile logs are ignored and never committed.

| Dataset | Speech-only mic / system seconds saved | Continuous bytes | Speech-only bytes | Compressed saving |
| --- | --- | --- | --- | --- |
| English overlap | 23.168 / 19.520 | 3,990,302 | 3,926,074 | 1.61% |
| Mandarin/Japanese overlap | 22.176 / 18.112 | 3,655,376 | 3,588,161 | 1.84% |
| Faint/short speech + noise/chords | 13.984 / 11.200 | 7,114,186 | 2,395,037 | 66.33% |
| Digital silence | 0 / 0 | 114,711 | 0 | 100% |

Gzip already compresses digital silence very well, so deleting many seconds does not
necessarily save many compressed bytes. ASR work and playback duration can still be
reduced. These figures depend on the content and do not predict arbitrary meetings.

Unpaced two-source write/VAD wall time was 2.53–2.59 seconds per 45-second concurrent
session (RTF 0.056–0.058), versus 0.97–0.98 for Continuous. CPU time was 2.52–2.57
seconds versus 0.96–0.97. Sampled harness RSS was about 30–32 MiB versus 17–18 MiB.
Those are accelerated CPU-only tests, not live-capture load measurements.

A separate real-time-paced bounded enqueue test ran the two modes sequentially:
Continuous wall 45.009 s / CPU 2.846 s / mean sampled CPU 6.45% of one core / peak
RSS 18,496 KiB; speech-only wall 45.007 s / CPU 6.556 s / mean sampled CPU 14.25% /
peak RSS 33,360 KiB. No enqueue/admission failures occurred. ps sampling was every
0.5 seconds; CPU time is process clock() across its threads, excluding gzip children.
The native detector never initialized Metal. No simultaneous heavy multimodal
benchmark was run; initial build recompilation was completed before VAD comparisons.
These are host proxies, not energy in joules or a blanket responsiveness guarantee.
Real OS capture/UI overhead, larger channel counts and long-call workloads still need
profiling. Model state grows with channel count; speech-only supports Float32 8–192
kHz up to 16 channels. Callback queues remain bounded at 64 buffers/source.

Gated English ASR/diarization smoke processing completed six chunks with microphone
and system transcript spans and no queued/failed chunks. The smoke coincided with
packaging compilation, so its timing is not a clean comparative benchmark. All
processing was local and sequential. A separate gated Mandarin/Japanese Whisper
smoke also completed six chunks (three microphone spans / four system spans). Some
Chinese/short-span language tags remained uncertain, and a short tail artifact was
retained rather than silently deleted. Pipeline completion does not establish word
accuracy or real-person diarization accuracy. Actual hardware/TCC dialogs, receiver unplug,
wireless transmitter loss, real-speaker overlap/echo, screen lock and sustained real
capture remain untested; no permissions were requested/accepted and no real audio
was captured. Journal.refresh retains its previously documented synchronous metadata
lock limitation.

## Reproduction

After quitting Nagi, build with `./scripts/build.sh` and open `build/Nagi.app`.
The native helper now exports the pinned SDK's stream reset operation; copying an
older helper produces an explicit incompatible-version error rather than silently
using it. The regular full test command is documented in SYSTEM_AUDIO.md.

The harness opens only supplied files and never a device:

```
.build/debug/JournalHarness dual-gate /tmp/NagiGateData /path/to/generated-mic.wav /path/to/generated-system.wav "$PWD" speechOnly
```

Use continuous for comparison, append `20` for an intentional abrupt crash, or
append `-1 realtime` for paced bounded-queue injection. Recover with
`.build/debug/JournalHarness recover DATA`. Use separate fresh data roots per run,
never the regular journal or private recordings. The profile fixture-builder and
raw logs are in ignored reports/dual-gate-fixtures and reports/dual-gate-bench.
