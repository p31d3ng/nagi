# Navigation clicks — Nagi 0.4.4, build 11

Primary sidebar rows and Settings-section buttons now define a rectangular hit
area inside their full padded labels, including trailing whitespace. Their plain
button style previously had no explicit content shape. They also explicitly allow
window-activation events using macOS 15+ SwiftUI's public API; this is scoped to
navigation, not recording/deletion or other actions. They remain standard Buttons
with native accessibility/keyboard behavior and selected-state traits. No mouse-only
onTapGesture replaces their actions.

Actual single coordinate clicks in blank trailing space switched Live/Settings
and wide/minimum-width Devices sections in the recording/network-disabled UI.
Focus was switched away with Cmd-Tab before additional single-click tests, which
also switched sections. Automation can activate a targeted app before sending
input; those tests are not independent proof of physical first-mouse behavior.
The public activation policy is enabled explicitly. Tab did not move accessibility
focus in this host's test window; no global keyboard preference was changed.
Standard Button semantics/accessibility remain, but hardware keyboard navigation
with the user's preferred OS configuration needs confirmation.

Tab actions only change view state. Settings performs no model load; Models checks
local file presence. Timeline already uses lazy stacks. Live's page query had run
synchronously on the main actor and could wait on the serialized database lock.
That read now runs on one utility queue, with one active read and one latest pending
request. Cancelled/outdated results cannot replace a newer session, and switching
away invalidates pending results. This removes that potential lock wait from the
main actor; it does not claim to diagnose or eliminate all causes of sluggishness.

## Verification

96 tests passed, zero failures, in 15.639 seconds. New tests cover stale-result
cancellation, bounded/coalesced reads and keeping the main actor responsive during
an 80 ms simulated read. The test originally used fixed sleeps to await callbacks;
it was changed to publication expectations to avoid timing assumptions.

5,000 synthetic spans, 50 bounded 200-row page queries: 0.03385 seconds total,
0.677 ms mean/query. This does not establish a general database performance problem.
101 refresh requests scheduled in 0.093 ms on MainActor; simulated 80 ms contention
resulted in two reads, not 101 queued reads. Tool round-trip/screenshot times are
not measured app frame or click latency.

UI used isolated synthetic text without audio or credentials, verified release
metadata 0.4.4/build 11, full-height sidebar, accessible selected buttons, actual
single whitespace clicks at wide and 660-point Settings widths, and Live data
arrival after navigation. No OS permission request, capture or real upload occurred.
Normal Nagi was restored after idle checks with unchanged journal/profile counts
and unchanged settings/profile fingerprints; Keychain was untouched.

System-audio work remains at API/design verification, with no capture implementation
in this release. A read-only attempt to verify private summary input validation
was blocked by SSH-agent signing failure; backend compatibility must be verified
before source-bearing summary changes. No private backend or contract changed.

Profiling also found avoidable same-value publications during metadata refresh.
Saving details, expiry, failure lists and synthetic idle status now publish only
when changed; the synthetic elapsed meter no longer advances a finished session.
A two-second sample of the large synthetic two-window case showed UI layout work,
not ML. Earlier three 1-second ps samples were 22.4–31.4% CPU with 215,744 KiB RSS.
After equality guards, four comparable idle samples were 0.0%, 0.5%, 0.1%, 0.6%
with stable 231,872 KiB RSS (~226 MiB); CPU time changed from 9.46 to 9.52 seconds.
Normal idle before this mitigation was already 0.0% CPU, stable 167,696 KiB RSS
(~164 MiB), unchanged CPU time. These short host proxies establish a reduction in
this stress case, not a broad energy/latency guarantee or proof of every reported
sluggishness cause. No additional model/inference behavior changed.
