# Optional system audio — Nagi 0.5.0, build 12

Enable **Settings → Devices → Include system audio for new conversations**.
It is off by default. The selected microphone still uses its stable UID and never
falls back. Grant system-audio access using the separate explicit request button,
then check again; macOS may require quitting/reopening Nagi. Requesting access
never starts capture. Start explicitly once both permissions and the receiver are
available. Enrollment remains microphone-only.

System audio uses ScreenCaptureKit, macOS 15+, with capturesAudio enabled,
captureMicrophone disabled, excludesCurrentProcessAudio enabled, and the current
process excluded from the content filter. Only an audio stream output is registered;
no screen frames, screenshots, screen movies or pixels are stored. A connected
available display is required by the selected SCK filter. This API choice follows
[Apple's ScreenCaptureKit explanation](https://developer.apple.com/videos/play/wwdc2024/10088/)
and was compiled against the installed macOS SDK, with no new third-party dependency.
The system track retains SCK's configured 48 kHz stereo Float32 samples, not a claim
about the physical output device's original sample rate. The microphone retains its
native input rate/channels. Each source has its own losslessly gzip-compressed CAFs.

Both sources must start successfully. Preparing can be cancelled; Cancel closes admission immediately and a late SCK
startup cannot reopen it. Denied permission,
missing display/device, buffer/clock errors or an SCK interruption finalize/cancel
both sources with an explanatory status. Admission closes and accepted buffers drain
before finalization. Late callbacks cannot append. While SCK shutdown acknowledges,
new starts are disabled. Quit drains files, requests stream shutdown and allows a
10-second acknowledgement window; process termination/crashes are recovered at
startup. Sleep stops recording with an explicit gap; locking/closing a window does
not deliberately stop it, but actual SCK screen-lock behavior remains untested.

Dual-source conversations use continuous saving even when the single-microphone
preference is Speech only; the preference itself is preserved. Dual-source recording
does not use VAD to omit audio and provides no speech-only storage savings. Quiet chunks may skip
ASR but recorded audio remains. The streaming microphone preview is suspended for
dual-source capture so archival ASR and diarization remain sequential on the existing
processing lane. Completed source-labelled spans appear in Live and Timeline.

Microphone AVAudioTime and SCK presentation timestamps share a host-time anchor and
session wall-clock origin. Implausible/missing timestamps use an explicitly uncertain
arrival fallback, never eligible for echo analysis. Timestamp discontinuities create
source-specific gaps rather than flattening both tracks onto one audio timeline.
Session/source status, gaps, chunk origin and clock quality survive in SQLite through
separate additive tables; old chunks remain explicitly Original audio. Existing
chunk/segment column layouts and original/corrected text are preserved.

Transcript origin is separate from speaker identity. Timeline and Live show origin
labels. Conversation playback has a source selector; sentence/evidence playback uses
its own source and seeks within that track. Playback never advances into the other
source. Start-of-track playback reports any initial gap and begins at its first saved
span; later undocumented gaps stop playback. Speaker labels still use Community-1
and the local profile, without treating System audio as a person.

Possible echo is a conservative audio-correlation hint only: bounded overlapping
host-clock windows, downsampled to 2 kHz, lags 20–500 ms, minimum agreement 0.985
across three windows. It runs after ML on the same serial lane. Hints may be dismissed
and restored. Nothing deletes, merges or suppresses audio/text/speaker labels, and
nothing performs or guarantees acoustic echo cancellation. Matching repetitions can
still produce false hints; double-talk, drift and real-room acoustics can miss hints.
Headphones reduce acoustic leakage. Excluding Nagi's own digital output does not
remove speaker output picked up acoustically by the wearable microphone.

Both sources and derivatives retain the original 48-hour expiry, startup/wake
cleanup and backup exclusion. Expired playback is refused while transcript text is
retained under the existing deletion/cap policy. Physical expiry cannot execute while
the Mac/app is offline; cleanup happens when it runs again. The transcript cap and
voice profile are unchanged. No audio/profile upload, deployment or credentials were
introduced. Existing optional summaries keep their opt-in settings and wire fields,
IDs and speaker identities. Coalescing cannot cross origins; local evidence resolves
origin from the existing segment ID. The backend is unchanged and receives no new
source or echo-annotation fields. It cannot interpret these local hints or reliably
recognize duplicated speech from them; both tracks' finalized text can reach the
service under the existing explicit manual/automatic summary consent. A future
backend source-aware display needs an explicit contract change.
No real summary requests occurred in these tests.

## Verification and limits

115 unit/integration tests passed, zero failures, in 26.605 seconds on macOS
26.6.2 (25G83), Xcode 26.6 (17F113), including shared timestamp validation and interrupted startup refusing further
admission/permission enumeration. Tests cover denied permission without content enumeration,
SCK configuration/PCM copying, bounded oversize rejection, gaps/clock errors, late
buffers after finish, source-isolated ASR context and playback/seek, source recovery,
48-hour expiry/derived removal, preserved raw/corrected text, reversible hints,
summary schema/source separation, delay, silence/noise, overlap and independent
repetition. Samantha/Daniel generated voices tested leakage and competing speech;
synthetic similarity does not establish real-person identification accuracy.

A process-level abrupt exit (75) at 12 seconds recovered the sealed 10.000-second
chunk plus a 2.288-second CAF tail, with both source statuses marked interrupted.
This test interrupted the first source during the synthetic harness's sequential
file injection; it does not prove every simultaneous physical-capture crash case.

Two-source write stress injected 120.064 seconds per source (48 kHz microphone mono,
system stereo), preserving all 5,763,072 frames per source across 26 chunks. Capture
write wall time was 2.544 seconds and compression 1.884 seconds, combined RTF 0.037
against concurrent session duration. Each live writer admits at most 64 buffers of
8,192 frames; SCK admits at most stereo, while the microphone retains device channels.
Inputs above 32 channels are refused explicitly. This bounds queued microphone
sample memory at 64 MiB (ordinary mono is 2 MiB), plus 4 MiB for system stereo,
excluding current callback buffers, objects and the separate worker processes.
A queue overflow stops with an error instead of blocking on ML or growing memory.
Disk backlog remains durable, not bounded by silent deletion: sustained live-call
throughput with a real device still needs testing.

Actual local workers ran on generated fixtures, with ps snapshots every 0.5 seconds
restricted to the harness and its descendants:

| Adapter + sequential Community-1 | Source audio seconds | Processing wall seconds | Observed tree peak RSS | Observed peak summed CPU |
| --- | --- | --- | --- | --- |
| Parakeet Unified EN 0.6B | microphone 9.567 / system 7.679 | 5.097 | 903,280 KiB (~882 MiB) | 87.7% |
| Whisper Medium Q4_K_M | Mandarin 9.061 / Japanese 7.065 | 4.341 | 695,040 KiB (~679 MiB) | 75.8% |

Both finished with zero queued/failed chunks. RTF against concurrent source duration
was 0.533 / 0.479 respectively. Mandarin script detection remained zh/ja uncertain;
Japanese was tagged ja script estimate. These short fixtures are not benchmarks of
long-call accuracy, sustained backlog, GPU memory or energy in joules. Sampled RSS/CPU
can miss brief peaks and shared pages can be counted twice. General slowdown or
screen-lock/hardware behavior is not established by these results.

The isolated capture/network-disabled UI verified version/build, explicit permission
controls, the default-off option, microphone/system transcript labels, both playback
choices, muted play/pause/resume/stop, navigation and the recovery/headphone guidance; a screenshot was inspected.
No real microphone/system stream was started, no permissions were accepted, and no
private recording or enrollment was used. Actual receiver unplug, wireless TX loss,
TCC dialogs, OS-initiated interruption and real-speaker echo/overlap remain untested.
Normal app idle: four 1-second samples were 0.0% CPU, stable 186,048 KiB RSS
(~182 MiB), with unchanged CPU time. Journal/profile counts and settings/profile
fingerprints matched before/after; system audio remained off and no recording was
active. Keychain was untouched.

Journal.refresh still has synchronous shared-lock metadata reads on MainActor, as
previously documented; this release makes no blanket responsiveness guarantee.

## Build, run and reproduce

After stopping recording and quitting Nagi, from this repository run
`./scripts/build.sh`, then `open build/Nagi.app`.
Rebuild/install instructions remain in INSTALL.md. Tests:

```
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift" swift test --disable-sandbox --scratch-path .build --cache-path .cache -j 4
```

Muted playback/TTS tests require host audio-service access. The deterministic source
harness accepts synthetic file paths, never opens an input device, and supports an
intentional crash and manual model selection:

```
.build/debug/JournalHarness dual-source /tmp/NagiSyntheticData /path/to/generated-microphone.aiff /path/to/generated-system.aiff "$PWD" -1 unified
```

Use `12` instead of `-1` for an abrupt synthetic capture crash, `recover DATA` for
recovery, and `whisper` as the final argument for multilingual fixtures. Do not point
this harness at the normal journal or private recordings. Detailed raw test/profile
outputs and generated audio stay in ignored reports/, not in the public repository.

Review fixes: queued system errors must match the current run, session and stream.
Startup cancellation preserves the first real source failure and any otherwise
unreported audio-flush failure. Genuine user cancellation is distinct in UI and
source status. Regression tests exercise stale callbacks after a new run, wrong
stream identity, failure provenance through cancellation/flush, and default-off
dual-source automatic summaries using a fake transport with zero requests.
