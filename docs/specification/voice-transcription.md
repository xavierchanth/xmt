# Voice Transcription specification

Voice Transcription dictates speech into text using Apple's on-device speech analysis, keeps the result on the clipboard, and can paste it into the focused input. This page specifies the behavior implemented in the `XMT` target: the platform floor, the module lifecycle, the Fn gestures and their arbitration, permissions, speech assets, input-device selection, capture and recovery, transcript commit, and the settings and menu surfaces. Configuration file syntax, precedence, and reload are specified separately in [configuration](configuration.md).

This is a specification of released behavior, not a design target. Every claim was read from `XMT/VoiceTranscription/`, `XMT/Triggers/`, `XMT/Configuration/`, `XMT/Settings/`, `XMT/MenuBar/`, `XMT/App/`, and `XMT/Resources/Info.plist`, and from the tests in `XMTTests/`. Where this page and the source disagree, the source is correct. For where the module is going rather than where it is, see [the module model](../architecture/modules.md#voice-transcription); for what has and has not been exercised on real hardware, see [the roadmap](../roadmap/README.md#voice-transcription-validation-gaps).

Normative language: **MUST**, **MUST NOT**, and **MAY** in this document describe invariants the current implementation upholds, not requirements on future work.

## Platform floor

The target's deployment target is macOS 26.0, and the speech types are compiled behind `@available(macOS 26.0, *)` with no alternative path for older systems. `SpeechAnalyzer`, `SpeechTranscriber`, and `AssetInventory` are used directly; there is no `SFSpeechRecognizer` fallback and no availability branch to remove later.

## Module lifecycle

The module is a main-actor singleton owned by the app delegate. It is compiled in, not registered through a general module list.

- At `applicationDidFinishLaunching`, XMT registers the module. Registration reconciles recovery artifacts, installs the paste-latest shortcut handler, migrates the former keep-last preference, then resolves and applies initial configuration in one authoritative task before any history operation. Only when effective history is enabled does it open history, import the legacy one-slot transcript, and load the newest row as Paste Latest. When effectively disabled it removes stale legacy plaintext without opening or creating SQLite and never removes recovery audio. Registration acquires no microphone, speech, or analyzer resource, and it prompts for nothing.
- When the app becomes active, XMT refreshes the input-device list and reloads configuration.
- At `applicationWillTerminate`, the module stops: the event tap observation is cancelled, the maximum-duration timer is invalidated, capture is stopped, the arming and analysis tasks are cancelled, any live transcriber is cancelled and its asset reservation released, and the partial transcript is cleared. A stop while a recovery recording is pending preserves that pending state; otherwise the session reducer is reset and the status becomes disabled.
- Enabling the module installs the Fn event tap and enables the paste-latest shortcut; disabling it performs the same stop as termination and disables both triggers. Neither requires restarting XMT.

The persisted enabled setting defaults to **enabled**, as do auto-paste, transcript history, and system-default fallback. History retention defaults to 30 days and 500 entries. The default locale is `en-US` and the default device-priority list is empty. Retention values bound the durable history store described under [durable history storage](#durable-history-storage).

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

Commit is ordered so the transcript survives every later failure. It is covered by `XMTTests/CommitSequenceTests.swift` and `XMTTests/TranscriptHistoryCommitTests.swift`.

1. The recognized text is trimmed of surrounding whitespace and newlines.
2. The clipboard is cleared and set to the transcript. A clipboard failure aborts the commit before anything else happens.
3. If **transcript history** is enabled, the transcript is appended to the durable history store and retention is applied in the same transaction. Failure aborts before recovery deletion and paste.
4. Recovery artifacts for the session are deleted. This deletion is the commit point.
5. Only then, if **auto-paste** is enabled and a trustworthy target application was captured, a logical Command-V is posted.

The module also keeps the transcript in memory as the last transcript. When history resolves enabled, registration loads the newest retained database row, so Paste Latest works across relaunch. With history disabled, a transcript committed during the current run remains available only in memory. The clipboard is never restored or wiped afterwards.

### Durable history storage

Retained transcripts are stored in `history.sqlite3` under `~/Library/Application Support/com.xavierchanth.xmt/VoiceTranscription/`. Unlike the former cache file, Application Support is durable application state and may be included in system or user backups; transcript text and its metadata therefore have the corresponding at-rest and backup privacy exposure. The behavior below is covered by `XMTTests/TranscriptHistoryStoreTests.swift`.

The database, its write-ahead and shared-memory side files, and the directory holding them are narrowed to their owner on every open — `0600` for files, `0700` for the directory — so an existing world-readable file from an earlier run is tightened rather than left open. Narrowing is best effort: a permission that cannot be set is not an error and does not deny the user their history.

Access is serialized: the store is an actor owning a single connection opened in SQLite's serialized threading mode, and it is the only writer. The schema is declared `STRICT`, carries the schema version in both `PRAGMA user_version` and a `schema_metadata` table, and is created idempotently on every open; a database whose version is newer than the running build — recorded in either place — is rejected rather than reinterpreted.

The schema is verified, not assumed. An existing `transcript_entries` is checked before anything is created against it, and the result is checked again afterwards: the columns must be exactly the six below, in order, and the table must still be `STRICT`. Any other shape is refused as incompatible, so a foreign table of that name can neither be read as history nor gain XMT's rows.

An entry holds exactly six values: identity, recorded instant in milliseconds, insertion sequence, transcript text, locale, and source state (`live`, `recovery`, or `legacy`). Source reveals how the transcript reached durable state but stores no application or recording identity. No target application identity, process identifier, audio path, or partial transcript is stored, because no column exists to hold one. Entries are listed newest first, ties on the recorded instant broken by insertion sequence, so commit order is total and presentation preserves that order.

Each append runs in one immediate transaction that inserts and then prunes, so history is never observed above its bounds. The insert is idempotent on the entry identity, which is the committing session's identity: a commit replayed after an interrupted run restores the same row rather than a second one. Retention prunes by maximum entries and, when retention days are set, by age; the newest retained entry is never pruned by an append.

Changing retention days or maximum entries — in Settings or through an applied configuration reload — applies at once rather than at the next transcript: the store adopts the new policy and prunes with it immediately, and later appends enforce the adopted policy. Tightening retention never causes the database to be created — the prune is applied only to a store that is already open, and never while history is disabled — and a widened bound restores nothing that earlier retention removed.

The former one-slot `last-transcript.txt` cache is imported at registration when effective history is enabled. Its deterministic identity and transactional completion marker make retries idempotent. The legacy file is deleted only after that transaction commits; a readable empty file is simply deleted, while unreadable data remains untouched and yields a content-free diagnostic. With effective history disabled, registration deletes the legacy plaintext directly without opening the database and leaves all recovery audio untouched.

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
- output settings — paste completed transcript, locale, copy last transcript, and the paste-latest shortcut recorder;
- transcript-history controls for enabled, retention days, and maximum entries;
- the ordered input-device priority list with add, reorder, and remove actions, plus the separate system-default fallback toggle;
- recovery actions, shown only while a recording is pending or failed;
- a configuration reload button and the last configuration diagnostic.

Controls whose value is supplied by the configuration file are disabled rather than silently overwritten; see [managed values](configuration.md#managed-values). A managed paste-latest binding preserves and later restores the user's prior recorder value. The hold threshold and maximum session duration have no settings control.

## Transcript history surfaces

The menu reads history when it opens and never on a timer. It lists the five newest retained transcripts as single-line previews collapsed to one line and truncated at 60 characters; choosing one copies that transcript. Below them are `Copy Latest Transcript`, which copies the newest retained transcript, and `Show All Transcripts...`, which opens the history panel. `Clear History...` is offered only when history is non-empty, and it never clears on the first press: it arms a confirmation, and the menu then offers `Confirm Clear History` and `Cancel Clearing History`. When history is empty the menu says so instead of listing previews.

The menu asks for only the five entries it can render, but that bound is a request, not the state. While the panel is open the request is served in full, so opening the menu never shrinks the list, the search, or the delete targets the panel is showing; a panel opened after a menu read likewise reads again rather than reusing the five-entry prefix. Once the panel closes, menu reads are bounded again.

The panel is a lazily created floating utility panel. Nothing is built, read, or observed until `Show All Transcripts...` is chosen, and closing it releases the panel, its captured paste target, and its search text. It lists entries newest first, filtered by a case- and diacritic-insensitive substring search whose blank query lists everything, and offers copy, paste, and delete per entry plus the same two-step clear.

With effective transcript history disabled, every surface is inert. The menu shows the single line `Transcript history is off` in place of previews, `Copy Latest Transcript`, `Show All Transcripts...`, and every clear action; `Show All Transcripts...` cannot be reached, and invoking the panel controller directly builds no window and captures no paste target. No read, delete, or clear reaches the repository, so a disabled history neither opens nor creates the database. Disabling also drops the loaded snapshot, any armed clear confirmation, the search text, and the captured target immediately, and re-enabling reads afresh. The Settings switch takes effect when it is changed rather than at the next configuration reload; while the configuration file owns the setting the switch is disabled and only an applied reload changes it. Nothing already written is deleted by disabling — retained transcripts stay in the database until they are cleared or pruned. Recording, `Copy Last Transcript`, and Paste Latest continue to work from the in-memory last transcript.

Paste from a history surface uses the application that was frontmost immediately before the surface took key focus, captured as a PID with its bundle identifier. Before any event is posted, that capture is re-verified: a target that is XMT itself, older than five minutes, no longer running, or whose PID now belongs to a different bundle identifier is refused. In every refusal — and in every posting failure — the transcript has already been written to the clipboard and is never removed from it, so the user can always paste manually. A blank transcript is neither copied nor pasted, and overlapping paste requests are dropped rather than queued.

Reading, deleting, and clearing go through a repository over the durable history store. A storage failure leaves the surfaces populated and shows a diagnostic instead of pretending the action succeeded. A failure opening the process-wide store is cached for the remainder of that process; explicit UI reload does not retry it, avoiding repeated disk work, and relaunch is the retry boundary.

## Related documentation

- [Configuration](configuration.md) — the file that governs these settings, its schema, precedence, and reload.
- [Module model](../architecture/modules.md#voice-transcription) — where this module sits in the intended architecture.
- [App shell](../architecture/app-shell.md#trigger-providers) — the intended trigger, permission, and lifecycle rules this module follows.
- [Roadmap](../roadmap/README.md#voice-transcription-validation-gaps) — what remains unvalidated on real hardware.
