# Live transcript verification

The measurements below describe the 0.2.0 baseline. Nagi 0.2.1 adds event-driven text updates, a selectable shorter-context default, and continuous conversation playback; see [the new comparison](PLAYBACK_LATENCY.md).

Nagi 0.2.0, Apple Silicon M1 Ultra Studio, macOS 26.6.2. English uses the pinned exact Parakeet Unified EN 0.6B Q8_0/transcribe.cpp engine. All input below was generated synthetic macOS TTS; no ambient microphone or human enrollment was performed by the test harness. All artifacts are ignored local `reports/` data.

## Behavior and resource design

The Live tab shows a selectable, auto-following conversation panel. Scrolling pauses following; Jump to live resumes it. Rendering is bounded to 200 paragraphs, with older pages accessible. Capture writes original-rate/channel audio first, then offers its immutable buffers through a separate 64-slot live feed. Resampling/downmixing/pipe writes never run on the microphone callback. The same 64 slots retain post-write pre-roll during model warm-up, preventing a silent loss of the first words. A full live queue or crashed worker releases the live lease and returns to the durable chunk pipeline; archival capture remains independent. Original CAF chunks are compressed on the serialized archival lane while live ASR runs.

One persistent, network-denied C++ worker keeps the English model loaded, uses Metal/two CPU threads, and emits committed/tentative/current hypotheses. It resets streams every 30 seconds to bound text/context state, while retaining the loaded model. Default Unified context is L=5.6 s, C=1.04 s, R=1.04 s. Current full text is authoritative; tentative text is dimmed only when the committed/tentative seam reconstructs that full hypothesis. Preview boundaries/revisions can omit or change words; preview text is not promised as final or precisely aligned.

Final archival ASR/alignment and Community-1 diarization run after the live worker exits. This avoids concurrent ML models in the ordinary pipeline but deliberately defers a growing number of finalization jobs during Live. Counts are visible; a long live conversation needs additional post-stop processing time. Finalization re-decodes archived audio using the existing boundary-context pipeline. It replaces complete preview ranges instead of appending duplicate preview words, and never writes over user corrections. Audio retention continues independently. Expired audio that cannot be finalized leaves its preview text with an explicit warning. Preview text counts toward the configured transcript capacity.

An activated preview continues across tab switches/window closure until Stop. Merely opening Live never starts capture. A later recording started outside Live uses batch updates. Multilingual Whisper remains chunk-based. Worker warm-up/overload has explicit status; Resume live preview retries while a recording is already active. There is no subsecond latency, no all-day stability, or competing-app slowdown guarantee from these tests.

## Actual tests

- **49 unit/integration tests passed**, zero failures. Added coverage includes paging bounds, complete-range preview replacement without overwriting a correction, preview capacity/expiry behavior, post-write sample positions, live lease compression and batch resumption, missing-model/cancel-before-start, recovered previews, and enrollment validation/preservation.
- **90 s preview-only run:** 1,440,000 mono 16 kHz Float32 frames, nine archival chunks; every archived sample equaled the repeated fixture. First nonempty text **2.075 s after feeding began**, 84 nonempty updates. Model warm-up excluded from that first-text measurement.
- **300 s full live pipeline:** 4,800,000 original frames, 30 chunks, **every sample equal**, all final jobs done, zero remaining previews after reconciliation. First nonempty text **2.080 s**, 279 nonempty updates. Controller wall **386.19 s**, including warm-up, final batch processing, sample audit and sampling overhead. Post-stop work therefore took about **85 s**; this is deliberately deferred alignment/speaker work, not live-feed latency.
- **Worker SIGKILL at 12 s of a 35 s session:** 560,000 original frames and four chunks preserved exactly; automatic batch recovery finished successfully. No lost archived frames.
- **60 s input at 50× speed:** bounded live admission reported overload and returned to batch processing. All 960,000 original frames/six chunks remained exact; final pipeline completed in 17.56 s controller wall. This accelerated test is not a latency benchmark.
- **Warm-up capture:** capture begins before model readiness; the first emitted preview retains the fixture opening words and starts at offset zero, with all original samples archived.
- **33 s stop/tail:** four archival chunks including a three-second tail, final preview flushed, 528,000 frames exact; final jobs finished.
- **48 kHz stereo/right-channel-only seven-second fixture:** six nonempty live updates, first at 2.154 s, original-rate/channel archival comparison passed. This exercises downmix/resampling rather than silently dropping the right channel.
- **100,000-row synthetic journal:** Live SQL returned its 200-row render window in **0.267 ms mean / 0.416 ms maximum** across ten local queries. Query plan used session/offset indexes and merged the bounded ordered streams.
- Native screenshot/accessibility inspection confirmed the rounded panel, final speaker labels, copy control, scrolling pause/Jump to live, and three repeated Timeline/Live transitions. Synthetic test controls stayed disabled. No normal microphone Start was pressed.

The fixture used by existing tests was generated before the naming cleanup, so some ignored synthetic transcript text still says the former working name. Tracked source/docs use Nagi.

## Profiling methodology and limits

`scripts/profile-live.py` samples the harness and recursive child processes every approximately 0.5 s using `ps` RSS/%CPU, retaining NDJSON on disk. `100% CPU` means one CPU core. RSS is resident working set, not live heap or precise physical memory. CPU averages/medians are sampled proxies, not direct energy measurements. Metal/ANE energy, watts and latency under competing workloads were not measured. GUI CPU is excluded from these process-family measurements; UI rendering was separately inspected/bounded, not profiled with live microphone capture.

| Synthetic run | Peak family RSS | Mean / median sampled CPU, one-core % |
| --- | ---: | ---: |
| 90 s existing batch, real-time paced | 896.5 MiB | 7.96 / 0.3 |
| 90 s live preview only, final ML excluded | 887.8 MiB | 3.47 / 2.5 |
| 300 s Live plus all deferred final ML | 898.2 MiB | 8.49 / 2.3 |

These rows have different work boundaries and durations; the preview-only row is **not** evidence that total live processing costs less than batch. Live incurs an additional preview decode, keeps ~0.9 GiB resident during recording, and still performs final archival decoding later. It avoids reloading the model for every preview update; a more complex future adapter could reuse live results for alignment, but this implementation retains the proven final pipeline.

During seconds 15–295 of the five-minute run, active family CPU averaged **2.33% of one core**. Worker RSS medians were 869.0 MiB at seconds 25–55, 871.6 at 65–95, 873.9 at 125–155, then **876.6 at both 185–215 and 255–285**. Harness early/late active medians were 15.38/16.19 MiB. This finite run shows warm-up followed by a short plateau, not a 24-hour proof. Output-audio-cursor lag was near zero in the paced fixture (feeding happens just before the harness waits); it is **not per-word recognition latency**. The defensible latency result is time to first nonempty preview from known fixture onset.

Local evidence folders include:

- `reports/live-profile-live-861e560d-1c1a-4793-b0c8-69f49cb67767` (five-minute full pipeline)
- `reports/live-profile-batch-15903e89-4503-4418-b1a5-87e083a102ac` (batch baseline)
- `reports/live-profile-live-c3ea919c-f71c-4cbb-aa02-cae2014a9a38` (90-second preview)
- `reports/live-profile-live-271ce41b-3486-4e85-9b76-f56a0984b7ef` (worker crash)
- `reports/live-profile-live-231ac82a-8d23-44c7-ba76-c15e0866dec4` (backpressure)
- `reports/live-profile-live-0ae19171-4ff0-4de7-bce2-6210fd717f09` (short tail)
- `reports/live-profile-live-2cab9014-88e1-4e61-8bc4-9d8d359bfbea` (48 kHz stereo)
- `reports/live-query/summary.json`, `reports/live-warmup-tests.log` and `reports/enrollment-sdk/summary.json`

Reproduce synthetic tests after model/fixture setup:

```sh
./scripts/build.sh
python3 scripts/profile-live.py live 300
python3 scripts/profile-live.py batch 90
python3 scripts/profile-live.py live 35 12
python3 scripts/profile-live.py live 60 -1 50
```

## Enrollment recovery

Enrollment now collects Community-1 vectors from usable clear-voice chunks and commits one consistent profile only after the whole session finishes. Short stop tails do not invalidate good long chunks. Empty, invalid, mixed or failed samples cannot report successful saving, and a failed new enrollment preserves any existing profile. Capture that has delivered no frames after roughly five seconds stops with an actionable warning; zero-valued audio still counts as delivered frames, so this does not equate silence with transmitter disconnection.

The regression covers the missing-profile case: a finished enrollment session with zero audio chunks contains no recoverable voice sample. Such a session must show an actionable failure rather than a successful-save message. Re-enrollment with visible input levels and explicit successful-save confirmation is required; changing matching thresholds cannot recover missing audio. Existing Me similarity/margin thresholds remain unchanged.

A separate real-SDK synthetic enrollment passed with two ten-second speech chunks plus a 0.1-second tail: one compatible 256-dimensional Community-1 profile was committed after completion. This used only generated speech in an isolated test journal.

Real receiver unplug/TX radio loss, real-speaker recognition, screen lock/sleep/wake with actual hardware, multi-hour live operation, and manual microphone stop/start cycles remain untested. The test UI used an isolated synthetic observer; it did not exercise real Core Audio permissions/capture. Synthetic voice enrollment is not evidence of accuracy on real people.
