# Voice Transcription hardware QA checklist

This checklist defines the deferred manual exercise for Voice behavior that cannot be validated safely in repository automation. It records a procedure, not evidence that any step has passed; current validation state remains in the [roadmap](../roadmap/README.md#voice-transcription-validation-gaps).

## Preparation

- Use a disposable macOS user account or otherwise record the existing Microphone, Input Monitoring, and Accessibility grants before changing them.
- Have a built-in microphone, a Bluetooth microphone if available, an ordinary text editor, and a non-US keyboard layout available.
- Preserve any pending Voice recovery files before destructive recovery checks.
- Record the XMT build identifier, macOS version, devices, keyboard layouts, permission state, and observed result for every run.

## Launch and permissions

- Confirm launch causes no TCC prompt, microphone acquisition, speech-asset download, or recording.
- Walk `Request Required Access` from a state with no grants and verify Microphone, Input Monitoring, and Accessibility are requested only from that explicit action.
- Deny each grant in turn and verify the corresponding trigger or paste failure is concise and non-destructive.
- Disable and re-enable Voice and confirm the Fn observer and paste-latest shortcut release and reacquire without restarting XMT.

## Recording triggers

- Verify a bare Fn tap does nothing, a hold begins push-to-talk after the configured threshold, and release ends it.
- Verify Fn-Space starts and stops latched recording, converts active push-to-talk to latched, consumes only its matching Space events, and leaves unrelated Fn chords usable.
- Release Fn and toggle off during each slow arming phase; confirm recording never begins after cancellation.
- Exercise secure input during arming, push-to-talk, and latched recording; confirm capture stops, automatic paste/history are suppressed for the interrupted session, and no idle polling remains.
- Confirm Control-Command-V never starts or stops recording and never changes Fn or Fn-Space behavior.

## Capture, devices, and speech

- Record with each eligible wired or built-in input and verify UID binding, first-buffer behavior, transcript partials, finalization, and maximum duration.
- Check, download, reserve, and release a speech asset through the explicit controls; repeat with missing and unsupported locales.
- With a paired Bluetooth microphone, verify disconnected and ambiguous-name devices fail closed and system-default fallback follows its separate setting.
- Force a device loss and capture interruption, then verify one pending recording can be retried or deleted and no second recovery slot appears.

## Transcript output and paste latest

- With auto-paste on, record while a text editor is frontmost and verify the completed transcript remains on the clipboard and pastes to the PID captured at arm time.
- With auto-paste off, verify commit still updates the clipboard and latest transcript but posts no key events.
- Invoke Control-Command-V from a non-XMT editor and verify the current frontmost target receives the latest completed transcript using both US and non-US keyboard layouts.
- Invoke paste latest during recording and verify it pastes only the previous completed transcript, does not alter auto-paste, does not stop or start recording, and creates no additional retained item.
- Remove Accessibility trust and force a target/layout failure; verify the latest text remains on the clipboard and temporary feedback does not replace recording status.
- Invoke paste latest with no transcript and with XMT frontmost; verify concise temporary no-op feedback and no paste into XMT.
- Relaunch with history enabled and verify the newest retained database row backs Paste Latest; repeat with history disabled and verify no durable row is written.
- Seed `last-transcript.txt` and verify one-time import preserves its mtime, deletes it only after commit, and leaves unreadable data untouched with a content-free diagnostic.
- Change the paste-latest recorder binding, then manage it through version-1 configuration; verify config precedence, disabled recorder state, and restoration of the prior local binding after removing the key.

## Recovery and cleanup

- Interrupt XMT during capture and verify reconciliation converges to at most one usable pending recording after relaunch.
- Retry and delete pending recordings and verify successful commit clears all recovery artifacts without affecting paste-latest behavior.
- Confirm paste latest never writes history or deletes recovery artifacts; confirm clear, single delete, and disabling history also preserve pending recovery audio.
- Exercise menu and panel focus capture, target exit, Accessibility revocation, activation timeout, paste failure, single-delete confirmation, and clear confirmation; verify every failed paste leaves the selected transcript on the clipboard and never targets another app.
- With more than five retained transcripts and the panel open, open the menu and verify the panel keeps listing every entry, its search still matches beyond the newest five, and delete still targets the right row.
- Disable history through the configuration file, then delete the database and relaunch: verify the menu shows only `Transcript history is off`, no `Show All Transcripts...` is offered, and no `history.sqlite3` is recreated while the app runs.
- Inspect `history.sqlite3` and its directory with `ls -l` and verify owner-only modes; tighten retention days or maximum entries in settings and verify the excess entries disappear at once rather than at the next transcript.
- Restore the original permissions, keyboard layout, audio defaults, and retained/recovery files after the exercise.
