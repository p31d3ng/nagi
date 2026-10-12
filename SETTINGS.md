# Settings organization — Nagi 0.4.2, build 9

The main sidebar now contains **Timeline**, **Live**, and **Settings**. Settings
contains separate labeled sections for **Permissions**, **Summarization**,
**Devices**, **Models**, **Storage**, **Voice profile**, and **Dictionary**. The
section selector wraps to fit the window. Selecting a section stays within
Settings, and Timeline/Live navigation remains available. The macOS Settings
command (⌘,) opens the same Settings interface. Old internal initial-section
names still route into the appropriate Settings subsection.

Existing controls and their shared Journal/SummaryController bindings remain:

- Devices: stable-UID input selector, disconnected-selection recovery, sleep
  preference, receiver/wireless-loss explanation and Save settings.
- Models: manual ASR selector, model revision/language/installation status,
  caveats and Save settings. Selecting a model does not run inference.
- Storage: audio-saving mode, 48-hour audio policy, transcript cap/MB entry,
  eviction explanation, local data path, cleanup and Save settings.
- Permissions, Summarization, guided profile enrollment/deletion, preferred words
  and exact replacement rules remain available in their own sections.

Navigation links/instructions now refer to Settings → Devices/Storage. An old
Storage sentence incorrectly said no endpoint existed; it now identifies the
optional transcript-only service configured in Summarization. No recording,
inference, retention, authentication or automatic-summary default changed.

The sidebar displays the app version. Settings displays version and build number.
Both read CFBundleShortVersionString/CFBundleVersion from Bundle.main; neither UI
hardcodes a release number. Missing debug metadata displays "Development build ·
version unavailable" and/or "build number unavailable" instead of inventing a
version. The packaged bundle and inspected UI both show **0.4.2 / build 9**.

## Verification

The final full suite passed **90 tests**, zero failures, in **14.241 seconds**.
Three new tests cover bundle version/build display and missing/partial/malformed
debug metadata; existing permission, capture, processing, retention and summary
regressions passed. Reproduce with:

    ./scripts/build.sh
    open build/Nagi.app
    CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/swift" swift test --disable-sandbox --scratch-path .build --cache-path .cache -j 4

UI verification used an empty isolated journal, a synthetic disconnected UID and
an invalid test endpoint without a bearer. All seven Settings sections were
visited. The disconnected selector recovered through selection of a connected
input, without opening capture. Input/sleep/model/capacity/dictionary changes
saved and reloaded after process restart. The cap toggle disabled/enabled the
capacity field; continuous saving persisted; local cleanup ran against empty test
data. Permissions refreshed read-only, Summarization remained off with no
credential, and voice-profile controls remained present without being activated.
Window close/reopen preserved app functionality. An inline screenshot confirmed
section layout, selected-section indication and both visible version labels.
No real microphone request/capture, enrollment, inference or upload occurred.
Physical receiver unplug/reconnect was not tested; device monitoring logic is
unchanged. Synthetic disconnected/connected selector states are not hardware proof.

Normal user data was checked for active capture/processing/submissions before
restoration. Normal Nagi was restored with unchanged session/chunk/transcript/profile
counts and unchanged settings/profile fingerprints. Existing endpoint/automatic
preferences and credentials were untouched. Test artifacts and fingerprints stay
in ignored reports; no recordings, profiles, secrets or private backend code enter
the source commit. Development builds continue to use the existing ad-hoc signing
and same local.nagi.journal bundle identity/path.
