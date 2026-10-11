# Optional transcript summarization — Nagi 0.4.0

## Configure and use

Open **Settings → Summarization** (also available through macOS Settings).
The verified HTTPS endpoint is prefilled. Save a changed endpoint first, then
enter the **original app bearer** and choose **Save bearer in Keychain**. This is
not the Cloudflare deploy token or the server's SHA-256 digest. The field never
loads a stored credential into the UI. Verification did not retrieve,
generate, insert or test with a real credential; the user enters their own.

Select a saved conversation and choose **Summarize** after final local processing.
The current corrected text, speaker labels and original elapsed timestamps are
sent to the configured service. No audio, device UID, voice-profile embedding,
raw decoder output, dictionary or recording settings are included.
Generated overview/highlights/decisions/actions, model, transcript revision,
source references and uncertainty are saved locally. All summaries require review.
Evidence buttons start local playback at source times while audio is available.
The backend's known semantic quality limitations are not fixed by this release.

Automatic submission is **off by default**. Enabling it grants consent only for
normal recordings started while enabled, after capture successfully starts.
Current/historical recordings, enrollment and imports are not enrolled by toggling
it on. Submission waits for Stop/interruption recovery and successful final ASR
and speaker processing. Live previews never enter the exporter. Silence is skipped
without an HTTP request. Failed processing waits for explicit local recovery and
cannot starve later finalized recordings.

Disabling automatic submission revokes pending consent and cancels automatic
requests. Editing an endpoint pauses submissions immediately; a changed exact URL
requires its own credential and fresh opt-in. Removing a credential disables auto.
Cancellation stops local waiting, not already transmitted data or remote inference.

## Privacy, durability and bounds

- Credentials use a nonsynchronizing, device-only macOS Keychain generic-password
  item scoped to the exact canonical HTTPS URL. Attribute presence is checked at
  launch; secret bytes are read only when a submission is authorized. Locked or
  inaccessible Keychain fails visibly without prompting in the background.
- HTTPS is required. URL credentials, query parameters and fragments are rejected.
  The ephemeral HTTP session has no cookie, credential or URL cache and refuses
  every redirect. Tests exercise the actual redirect delegate callback and prove
  no request reaches the synthetic second host.
- Error bodies, request headers and URLSession error details never enter the
  journal/logs. A response that echoes the bearer is discarded before persistence.
- One in-flight request per app, including across windows. A durable per-recording
  consent claim is consumed before transmission, including manual submission.
  In-flight claims recovered after restart become uncertain, never automatic retries.
  Explicit retries/regeneration require a confirmation that inference may run again.
- Transcript revisions change on edits/labels and final processing changes. Returned
  ID/version must match the submitted snapshot; responses to an edited conversation
  are retained as older/stale summaries, not silently attached to the current text.
- Source references must exist in the submitted snapshot. Source metadata is restored
  from local input rather than trusting the service. Decisions/actions render only
  validated quotes, reject empty evidence and reject extra unvalidated text.
  Quote validity does not prove semantic classification; review remains required.
- SQLite completion receipts are written atomically with terminal chunk state and
  preserved during expiry. Reprocessing invalidates proof. A late processing/expiry
  interleaving cannot permanently hide completed transcripts. Older expired data
  without completion proof remains conservatively unavailable for submission.
- Adjacent compatible spans coalesce without losing words; the timeline's 2,000-row
  limit is not used. Export checks all text (up to 4,096 source spans), 64 turns,
  4,000 characters/turn, and the exact 16 KiB JSON payload limit. Rejections send
  nothing and never silently truncate. Long-transcript paging is future work.
- Response storage is bounded at 128 KiB; request timeout is 65 seconds. Auth,
  quota, oversized input, redirect, timeout/network, cancellation and invalid/stale
  responses are handled locally. Ambiguous failures do not trigger repeat inference.
- Summaries count toward the existing transcript-text cap and cascade with whole
  conversation deletion/eviction. Audio/profile/retention policy is unchanged.

## Verification on this Mac Studio

83 tests passed in 14.72 seconds, covering original capture/playback/VAD/recovery
regressions and new security/finalization/export/state-machine tests. Muted synthetic
playback needs existing CoreAudio access; the restricted tool sandbox failed those
old playback tests, while the host test run passed. No microphone test occurred.

1,000 12-span exporter snapshots: 0.1790 seconds wall, 0.1783 seconds CPU
(~0.178 ms/export), maximum 623-byte payload; XCTest process peak RSS 88,244,224
bytes (~84 MiB). This is a host proxy, not Cloudflare CPU or inference latency.
Normal idle app: four 1-second ps samples at 0.0% CPU and 134,288 KiB RSS (~131 MiB),
with unchanged CPU time. A two-window synthetic UI test had stable ~144 MiB RSS
and brief rendering/accessibility CPU spikes; normal idle did not retain them.

Native URLSession HTTPS smoke: HTTP 401 unauthorized in ~0.176 seconds using an
intentionally invalid bearer and unfinished synthetic body; no inference possible.
Mock transport tests cover success, auth failure, ambiguous/cancelled requests,
restart claims, no history enrollment, manual/auto deduplication, failed-ASR backlog,
no-speech sessions, host changes, credentials echoed by a service, stale replies,
source validation, large payloads, actual redirect callbacks and response bounds.

Synthetic UI was inspected for Settings grouping/masked empty credential entry,
opt-in defaults, generated review warnings, evidence links, tab navigation and
window reopening. Test data/network-disabled mode used the same app bundle identity.
The rebuilt normal app was restored only after idle checks. Counts of sessions,
chunks, transcript spans and local profiles were unchanged; no submission/consent
row was created in normal user data. Keychain save/read with a real bearer and
live authenticated app inference remain for the user's configuration step.
No backend implementation, prompt, deployment or permission changed here.

## Reproduce

    ./scripts/build.sh
    open build/Nagi.app
    CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift" swift test --disable-sandbox --scratch-path .build --cache-path .cache -j 4

Safe native endpoint smoke (no Keychain or AI):

    .build/debug/JournalHarness summary-auth-check reports/summary-native-smoke

Ignored evidence: reports/summary-tests-reviewed-final.log,
summary-app-reviewed-final.log, summary-native-smoke.log, summary-normal-after.json,
and summary-ui/idle-profile.json. No user journal, fixture audio, credential, model
weight or backend private source is committed.
