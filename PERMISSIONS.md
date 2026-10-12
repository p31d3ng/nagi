# Microphone permissions — Nagi 0.4.1

Open **Settings** in the sidebar or press **⌘,**. The **Permissions** card reads
`AVCaptureDevice.authorizationStatus(for: .audio)` and shows Not requested,
Allowed, Denied, Restricted, or an unknown future status. It refreshes when the
card appears, Nagi becomes active (including returning from System Settings),
and when you press **Check permission again**.

**Request microphone access** is available only for Not requested. This explicit
button asks macOS for permission without opening an audio input or recording.
Start/Enroll retain their explicit permission flow. Denied or restricted states
never re-request access. Follow **System Settings → Privacy & Security →
Microphone → Nagi**; macOS may require quitting/reopening after a change. The help
button opens [Apple's microphone-settings guide](https://support.apple.com/guide/mac-help/control-access-to-the-microphone-on-mac-mchla1b1e1fe/mac),
which includes Apple's supported Settings link. No undocumented pane URL is used.

Device availability is displayed separately: selected input connected, no
connected selection, or no input devices detected. Permission alone does not
prove the receiver is connected. Nothing silently selects a replacement input.
The synthetic UI mode disables permission requests and recording.

## Repeated prompt investigation

Source inspection found one prior requestAccess call, in Journal.start, already
conditional on notDetermined. It did not guard repeated Start/Enroll clicks while
a request was pending. The shared controller now serializes requests, rereads the
actual status after the callback, and skips requests for known states. It also
rechecks device UID/selection after a permission dialog before capture begins.
Enrollment state is no longer changed before permission is granted.

Capture uses AVAudioEngine/inputNode inside the main Nagi executable. ASRWorker,
LiveASRWorker, SpeakerWorker and gzip receive audio buffers/files and do not request
microphone permission or open capture devices. Capture.start opens the input node; stop removes its tap only after a writer was
attached. Refreshing the Permissions card never opens the input node.

The bundle ID remains **local.nagi.journal**, at the existing **build/Nagi.app**
path. Inspection of the previous 0.4.0 bundle found **flags=adhoc**, no signing
team, and a designated requirement based on cdhash
`bb18ef7a0c5212e178ed62697a9081daf916fdb8`. scripts/build.sh continues to use
`codesign --force --sign -`; rebuilding changes the executable hash and thus this
ad-hoc designated requirement. That is evidence of changing development signing
identity, and a plausible source of renewed prompts, not proof of the user's
specific TCC behavior. The status UI and single-flight guard cannot guarantee
permission persistence across development rebuilds. A stable trusted signing
identity would need a separately authorized signing/distribution setup.

No TCC database was read/reset, no security setting changed, no certificate created,
and no macOS prompt approved. Real OS permission transitions and repeated prompts
across actual recordings remain untested. The agent did not request microphone
access or capture ambient audio.

## Verification

Four mock permission tests cover all four statuses, read-only refresh, external
settings transitions/revocation, allow/deny callbacks, duplicate pending requests,
and skipping requests after a known decision. All 87 regression tests passed in
14.905 seconds, including existing muted synthetic playback (no microphone).
Build and synthetic Settings UI verification use the same bundle ID/path.

Synthetic UI inspection showed **Microphone · Allowed**, separately from **No
connected input selected**. Settings → Devices → Settings preserved the display;
request and editing controls remained disabled in synthetic mode. A screenshot
was inspected inline. After rebuilding, the designated requirement was cdhash
`726fcf2c4632874a15da3eb42040a544928d8ac3`, while this read-only UI check still
reported Allowed. A changed hash alone therefore does not establish a reproduced
permission reset in this test.

Normal Nagi was restored only after idle capture/processing/submission checks.
Session/chunk/transcript/profile counts and profile/settings fingerprints were
unchanged. Endpoint, automatic-summary preferences and existing journal/profile
data were preserved; no Keychain credential was read, entered, changed or removed
by the test.
