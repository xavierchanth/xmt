# Voice Transcription specification

Voice Transcription dictates speech into text using Apple's on-device speech analysis, keeps the result on the clipboard, and can paste it into the focused input. This page specifies the behavior implemented in the `XMT` target: the platform floor, the module lifecycle, the Fn gestures and their arbitration, permissions, speech assets, input-device selection, capture and recovery, transcript commit, and the settings and menu surfaces. Configuration file syntax, precedence, and reload are specified separately in [configuration](configuration.md).

This is a specification of released behavior, not a design target. Every claim was read from `XMT/VoiceTranscription/`, `XMT/Triggers/`, `XMT/Configuration/`, `XMT/Settings/`, `XMT/MenuBar/`, `XMT/App/`, and `XMT/Resources/Info.plist`, and from the tests in `XMTTests/`. Where this page and the source disagree, the source is correct. For where the module is going rather than where it is, see [the module model](../architecture/modules.md#voice-transcription); for what has and has not been exercised on real hardware, see [the roadmap](../roadmap/README.md#voice-transcription-validation-gaps).

Normative language: **MUST**, **MUST NOT**, and **MAY** in this document describe invariants the current implementation upholds, not requirements on future work.

## Platform floor

The target's deployment target is macOS 26.0, and the speech types are compiled behind `@available(macOS 26.0, *)` with no alternative path for older systems. `SpeechAnalyzer`, `SpeechTranscriber`, and `AssetInventory` are used directly; there is no `SFSpeechRecognizer` fallback and no availability branch to remove later.

## Module lifecycle

The module is a main-actor singleton owned by the app delegate. It is compiled in, not registered through a general module list.

- At `applicationDidFinishLaunching`, XMT registers the module. Registration reconciles any recovery artifacts left by a previous run, installs the paste-latest shortcut handler, and then loads configuration; applying that configuration loads `last-transcript.txt` when retention resolves enabled and starts Voice triggers when the module resolves enabled. Registration acquires no microphone, speech, or analyzer resource, and it prompts for nothing.
- When the app becomes active, XMT refreshes the input-device list and reloads configuration.
- At `applicationWillTerminate`, the module stops: the event tap observation is cancelled, the maximum-duration timer is invalidated, capture is stopped, the arming and analysis tasks are cancelled, any live transcriber is cancelled and its asset reservation released, and the partial transcript is cleared. A stop while a recovery recording is pending preserves that pending state; otherwise the session reducer is reset and the status becomes disabled.
- Enabling the module installs the Fn event tap and enables the paste-latest shortcut; disabling it performs the same stop as termination and disables both triggers. Neither requires restarting XMT.

The persisted enabled setting defaults to **enabled**, as do auto-paste, keep-last-transcript, and system-default fallback. The default locale is `en-US` and the default device-priority list is empty.

### Status values

One published status drives the menu and settings surfaces: disabled, idle, arming, recording, finalizing, pending, no speech, paste failed, degraded, and failed. Degraded, paste-failed, and failed carry a message string. Arming is refused unless the status is idle, so a gesture arriving during the two-second no-speech notice, the three-second paste-failure notice, or while a recovery recording is pending is dropped without effect.

## Triggers and arbitration

The module observes the Function key through a `CGEventTap` at the session tap, head insertion point, watching flags-changed, key-down, and key-up events. The tap exists only while the module is enabled and observing; it is created on demand and removed when the last observation is cancelled.

### Gestures

- **Hold Fn** starts push-to-talk once the hold threshold elapses. Releasing Fn ends it and finalizes the session.
- **Fn-Space** requests a toggle. From an idle Fn hold it starts a latched session; pressed again — as Fn-Space, or through the menu's stop action — it stops one.
- Pressing Fn-Space while push-to-talk is already active converts that session to latched, and the later Fn release does not stop it.

The hold threshold is **150 ms** by default and is settable only through the configuration file, within 50–500 ms. Changing it while the module is idle rebuilds the observer with the new threshold; a change that arrives mid-session takes effect after the session commits.

### Event mapping and consumption

Physical bookkeeping is deliberately separate from arbitration. While Fn is held:

- Space key-down is reported once per press; auto-repeat of Space produces no further gesture input.
- Space key-down and its matching key-up are **consumed**, so an Fn-Space chord does not reach the focused application. Every other event is passed through unmodified.
- Any other key-down while Fn is held moves the gesture into pass-through, so ordinary Fn chords such as Fn-F keep working.

The tap's synchronous callback decides consumption and returns; semantic callbacks to the module are always delivered asynchronously on the main queue afterwards.

### Arbitration states

The arbitrator is a pure reducer with four states — idle, Fn pending, push-to-talk active, and chord pass-through — and is covered by `XMTTests/TriggerArbitratorTests.swift`.

| From | Input | To | Emitted |
|---|---|---|---|
| idle | Fn down | Fn pending | none |
| Fn pending | Fn up | idle | none — a bare Fn tap does nothing |
| Fn pending | hold threshold elapsed | push-to-talk active | push-to-talk began |
| Fn pending | Space down | chord pass-through | toggle requested |
| Fn pending | other key down | chord pass-through | none |
| push-to-talk active | Fn up | idle | push-to-talk ended |
| push-to-talk active | Space down | push-to-talk active | toggle requested |
| any active state | tap disabled or secure input | idle | push-to-talk ended, if one was active |

A threshold that elapses after Fn is already released MUST NOT start push-to-talk.

### Secure input and tap interruption

While macOS reports secure event input — a password field, for example — the tap consumes nothing and starts no gesture, and an in-progress gesture is interrupted so its push-to-talk end is delivered. A watchdog polls secure-input state every 100 ms **only while a gesture is in progress**, and is invalidated as soon as arbitration returns to idle; the module runs no timer while idle. If macOS disables the tap by timeout or user input, the observer interrupts the gesture and re-enables the tap.

## Permissions

XMT requests nothing at launch. The declared usage descriptions are Accessibility, Microphone, and Bluetooth-always; there is no `NSSpeechRecognitionUsageDescription` key in `Info.plist`. The app is not sandboxed.

- **Input Monitoring** is required for the Fn tap. The module preflights access before creating the tap and, if access is absent or tap creation fails, reports the degraded message `Input Monitoring access is required` rather than prompting.
- **Microphone** is required to arm a session. Arming checks the live `AVCaptureDevice` authorization for audio; if it is not authorized, the session is refused with `Microphone access is required` and no prompt is shown from the trigger path.
- **Accessibility** is required for both synthetic paste actions: auto-paste and paste latest. Nothing else in the module uses it.

`Request Required Access` in Voice settings is the contextual request path: it asks for microphone access, Input Monitoring, and Accessibility trust. When a request grants access, the module clears its degraded state and starts observing.

## Speech analysis and assets

Each session creates a single-use analyzer: a `SpeechTranscriber` for the resolved locale using the progressive-transcription preset, driven by a `SpeechAnalyzer` at user-initiated priority with `whileInUse` model retention. Recognition runs against locally installed models, and the module contains no server-recognition path; the only network activity in the module is the user-initiated asset download described below. Locale support is resolved through `SpeechTranscriber.supportedLocale(equivalentTo:)`, and an unsupported locale refuses the session.

Assets are managed through `AssetInventory`:

- Settings shows an on-demand asset status — not checked, unsupported, missing, downloading, installed, or a failure message. Status is read when the Voice tab appears and on the `Check` button; nothing polls.
- `Download` performs an explicit installation request and reports its outcome. A second download while one is running returns the downloading status rather than starting another.
- Arming reserves the locale before creating the transcriber. If the reservation is refused, the session is refused with `Speech assets are not installed`. The reservation is released after commit, after failure, and on stop.

Audio buffers are converted to the analyzer's best available format by a single stream converter that preserves input order and flushes converter delay before ending analyzer input. Partial results update the published partial transcript; finalized segments are joined with a single separating space.

Finalization is bounded: a live session's finalization is cancelled after 5 seconds, and a recovery retry after 30 seconds.

## Input device selection

Selection runs once per session, from the user's explicit ordered priority list, and is covered by `XMTTests/DeviceSelectorTests.swift`.

1. Each priority entry is tried in order. An entry matches by device UID first, then by **exact** device name.
2. The first matching entry that is eligible wins. An ineligible match does not stop the scan; later entries are still tried.
3. If no configured entry is eligible, selection falls back to the current system-default input **only when the separate fallback setting is enabled**. Fallback is an independent choice, not an implied final list entry.
4. With fallback disabled and no eligible entry, selection fails. With fallback enabled, it fails if the system default cannot be read, is not present in the device table, or is itself ineligible.

A device is eligible when it is alive, has at least one input channel, and — for Bluetooth transports — is already connected.

### Bluetooth is fail-closed

Bluetooth link state is read from paired devices only; the module never starts discovery and never opens a connection. The Core Audio device table exposes no Bluetooth address, so matching falls back to the paired device's exact name, and **an ambiguous match is treated as not connected**. A Bluetooth microphone whose name matches zero or more than one paired device is therefore skipped rather than selected.

Any selection failure refuses the session with `No eligible input device`. The selection reads the system-default device but never changes it, and it never changes any other system audio setting.

## Capture and recovery

Capture binds one `AVAudioEngine` input node to the selected device by UID and taps it at the hardware format; no format is requested, because a tap format differing from the bound graph can raise an Objective-C exception. Each tapped buffer is copied and offered to a bounded queue of 32 buffers; sending never blocks the realtime thread.

A single drain worker writes every accepted buffer to a CAF recovery file **before** publishing it to the analyzer, so the recovery file is never behind what has been analyzed. Capture terminates the session, preserving what was written, when a buffer copy fails, when either bounded queue overflows, when no first buffer arrives within 1 second, when the engine reports a configuration change while the graph is no longer running, or when the bound device disappears. The engine is not restarted after such an event.

Recovery storage is a single slot under `~/Library/Caches/com.xavierchanth.xmt/VoiceTranscription/`, holding an active pair (`active.caf`, `active.json`) and at most one pending pair (`pending.caf`, `pending.json`). Metadata is versioned JSON — session identifier, timestamp, locale, and failure reason — written atomically through a temporary file; audio is never rewritten, only moved.

### Reconciliation

Reconciliation runs at registration and after a successful commit, and is covered by `XMTTests/ReconciliationTests.swift`. It converges every interrupted or corrupt state to exactly one outcome: clean, or one complete pending pair.

- Leftover atomic temporary files are swept first.
- Audio wins over metadata. Audio that is missing, unreadable, or empty is discarded; a pending sidecar with no usable pending audio is discarded rather than borrowed by a different recording.
- A usable pending recording is completed — a corrupt sidecar is replaced with conservative metadata using the `und` locale — and stale active artifacts are dropped.
- Otherwise, usable active audio is promoted into the pending slot, repairing or synthesizing its metadata.
- Sidecars without audio cannot recover content and are removed so they cannot block future recording.

Reconciliation is idempotent, and a commit that reports the transcript as committed deletes every artifact.

### Pending recordings

When a session fails after capture has started, its audio is promoted to the pending slot and the status becomes pending; if no pending recording can be formed, the status becomes failed with the error's description. A pending recording refuses new recordings until it is resolved. Both the menu and Voice settings offer exactly two resolutions:

- **Retry Recording** re-analyzes the pending audio file with a fresh analyzer at the recording's own locale and commits the result.
- **Delete Recording** removes the pending pair and returns to idle.

A retried transcript has no captured target application, so XMT skips auto-paste for retries and leaves the transcript on the clipboard.

## Transcript commit

Commit is ordered so the transcript survives every later failure. It is covered by `XMTTests/CommitSequenceTests.swift`.

1. The recognized text is trimmed of surrounding whitespace and newlines.
2. The clipboard is cleared and set to the transcript. A clipboard failure aborts the commit before anything else happens.
3. If **keep last transcript** is enabled, the text is written atomically to `last-transcript.txt` in the same cache directory, replacing any previous file. If it is disabled, an existing file is removed.
4. Recovery artifacts for the session are deleted. This deletion is the commit point.
5. Only then, if **auto-paste** is enabled and a trustworthy target application was captured, a logical Command-V is posted.

The module also keeps the transcript in memory as the last transcript, exposed as `Copy Last Transcript` in the menu and in settings. When keep-last-transcript resolves enabled, registration loads an existing nonempty UTF-8 `last-transcript.txt`, so that transcript is available after relaunch. With retention disabled, the file is not loaded; a transcript committed during the current run remains available in memory. The clipboard is never restored or wiped afterwards, so a failed paste still leaves usable text.

### Auto-paste

Auto-paste posts a synthetic Command-V key-down and key-up to the process that was frontmost **when the session armed**, excluding XMT itself. It resolves the physical key that produces an unmodified `v` in the current keyboard layout rather than assuming a US layout. It never writes Accessibility values.

When no target process was captured — including retries and sessions armed while XMT itself was frontmost — XMT skips auto-paste and leaves the transcript on the clipboard. When a target exists, paste can still fail without discarding anything if Accessibility trust is absent, the keyboard layout cannot be read, or the events cannot be created. A paste failure sets the paste-failed status with the error description for three seconds and then returns to idle.

### Paste latest transcript

The ordinary `KeyboardShortcuts` shortcut named `pasteLatestTranscript` defaults to Control-Command-V. On key-up it captures the application currently frontmost, excluding XMT, writes the completed last transcript to the clipboard, and asks the same keyboard-layout-aware paste service to post Command-V to that captured PID. This action is independent of auto-paste: it does not change that setting, enter the recording reducer, commit or retain text, delete recovery artifacts, or create a history entry. It remains safe during a recording because it uses only the previous completed transcript and publishes feedback separately from session status.

With no transcript, it changes neither clipboard nor target and reports `No transcript to paste` for two seconds. With no trustworthy target, it still leaves the transcript on the clipboard and reports `No target app; transcript copied`. Clipboard and paste failures likewise receive concise two-second feedback, and a delivery failure never restores or clears the clipboard. Disabling Voice disables the shortcut while leaving its handler installed inertly.

### No speech and failures

An empty trimmed transcript is not an error. Recovery artifacts are cleared, no clipboard write or paste occurs, the last transcript is left unchanged, and the status shows no speech for two seconds before returning to idle.

A session that fails before finalization completes follows the pending-recording path above. Arming refusals — missing microphone authorization, no eligible device, missing assets, unsupported locale — are reported as a degraded status and are not durable session state; the next gesture clears the degraded state and tries again. Refusals carrying a known reason report the messages quoted above; other errors report the underlying error's localized description.

## Session bounds

At most one session exists at a time. The session reducer is pure and single-flight, is covered by `XMTTests/SessionMachineTests.swift`, and drops any trigger that arrives in a state that cannot accept it. A recording is also stopped automatically after the maximum session duration — **300 seconds** by default, settable only through the configuration file within 1–3600 seconds — using the same stop path as the gesture that would have ended it.

## Menu and settings

The menu bar menu shows Voice state only when there is something to say: recording with a stop action, finalizing, a recording that needs attention with retry and delete actions, a degraded message, or temporary paste-latest feedback. `Copy Last Transcript` appears whenever a last transcript exists.

The `Voice` tab in Settings contains:

- the enable toggle, with the gesture hint for hold-Fn and Fn-Space;
- speech-asset status with check and download actions, the contextual access request, and the shared Accessibility status row naming completed-transcript and paste-latest delivery as its consumers;
- output settings — paste completed transcript, keep last transcript, locale, copy last transcript, and the paste-latest shortcut recorder;
- the ordered input-device priority list with add, reorder, and remove actions, plus the separate system-default fallback toggle;
- recovery actions, shown only while a recording is pending or failed;
- a configuration reload button and the last configuration diagnostic.

Controls whose value is supplied by the configuration file are disabled rather than silently overwritten; see [managed values](configuration.md#managed-values). A managed paste-latest binding preserves and later restores the user's prior recorder value. The hold threshold and maximum session duration have no settings control.

## Related documentation

- [Configuration](configuration.md) — the file that governs these settings, its schema, precedence, and reload.
- [Module model](../architecture/modules.md#voice-transcription) — where this module sits in the intended architecture.
- [App shell](../architecture/app-shell.md#trigger-providers) — the intended trigger, permission, and lifecycle rules this module follows.
- [Roadmap](../roadmap/README.md#voice-transcription-validation-gaps) — what remains unvalidated on real hardware.
