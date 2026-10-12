# Quick input and layout — Nagi 0.4.3, build 10

The shared recording bar has a compact **Input** picker beside **Start recording**,
including while viewing Live. Settings → Devices keeps the detailed selector and
explanations. Both bind to Journal.inputUID and the same selection method, which
persists only that stable UID immediately. It does not save unrelated model,
storage or summary preferences. No fallback or recording is triggered by selecting
an input. Enumeration updates through the existing two-second device monitor.

A disappeared remembered UID remains selected and visibly disconnected. Empty
input lists and no selected input are distinct. An input that disappears while a
menu is open is rejected. During recording both selectors are disabled, with
**Stop recording to change input** beside the quick picker; the persistence layer
also rejects active-recording changes. Capture stop/disconnection behavior is unchanged.

Settings now expands to the available pane width instead of the former 800-point
cap. Section chips wrap, text wraps, and long content scrolls vertically. The macOS
Settings window uses minimum sizing rather than an exact fixed frame. The recording
bar rearranges on smaller widths. The Live empty message is a centered overlay in
the available transcript pane, rather than an item at the top of its scroll stack.
The supplied Library screenshot was materialized/inspected to verify the referenced
empty-state layout; its bytes remain in ignored reports and are not published.

Three new deterministic tests cover UID persistence, no fallback across simulated
disconnect/reconnect, active-recording/stale-menu rejection and no-input states.
The full app suite passed 93 tests in 14.483 seconds. Installer verification is
reported separately in INSTALL.md. No new recording/inference/retention/authentication
or automatic-summary default changed. No system-audio capture is included in this
release; that is the next separately scoped feature.

Final UI checks covered 660-point synthetic minimum, 900-point default Settings,
and 1280-point synthetic wide layouts. The geometry fixture is available only
with recording/network-disabled NAGI_SYNTHETIC_MONITOR=1 and a bounded
NAGI_SETTINGS_TEST_WIDTH value; it has no effect in normal launches. Credential
actions stack rather than truncate at narrow widths. The full-height sidebar
has one upper-left native toolbar toggle in expanded/collapsed states, including
the Settings window's compact toolbar; the toggle remains accessible when hidden.
Recording controls stay inside the detail pane. The supplied sidebar/toggle
screenshots were also materialized/inspected locally and remain ignored.

Normal Nagi was restored after idle checks, with unchanged journal/profile counts
and unchanged settings/profile fingerprints. No actual microphone/system capture,
OS permission request, enrollment or real upload occurred. Physical hardware
reconnect behavior remains untested. No system-audio implementation has begun;
it remains the authorized next separate feature, with preserved mic-only behavior.
