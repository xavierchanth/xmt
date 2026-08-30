# Keyboard Customization destructive Stage 2 protocol

This is a future test procedure, not authorization. Stage 2 did not occur during the Stage 1 spike. It requires separate written approval, granted Apple entitlements and matching profiles, signed/notarized components, a disposable external keyboard, and an independent emergency keyboard. Never use the built-in keyboard or a firmware-managed/Voyager device.

## Proposed trust boundaries and identifiers

The existing app remains `com.xavierchanth.xmt`. Proposed separately signed boundaries are virtual-output dext `com.xavierchanth.xmt.virtualkeyboard`, task-scoped grabber `com.xavierchanth.xmt.keyboard.grabber`, watchdog `com.xavierchanth.xmt.keyboard.watchdog`, and versioned XPC service `com.xavierchanth.xmt.keyboard.lease.v1`. These latter three are design identifiers only: no targets, profiles, installation, or launch configuration exists. The GUI grants a renewable lease; the grabber alone may own a selected device; the dext only emits virtual reports; the watchdog observes lease/heartbeat and terminates the grabber. The Stage 1 [build evidence](keyboard-driverkit-feasibility.md) records the Apple-managed DriverKit entitlements and signing blocker.

## Preconditions and abort rules

1. Record approval, component hashes, OS/build, profiles and granted entitlements; never infer a grant from an entitlement file.
2. Disconnect all non-test keyboards except the emergency keyboard, then attach one disposable external test keyboard. Confirm the allow rule uniquely identifies it and explicit excludes cover built-in and Voyager identities.
3. Confirm a physical stop control independent of the test keyboard, uninstall/rollback artifacts, console access, and an observer with the stop procedure.
4. Verify virtual output readiness and a valid GUI lease are observable before any seizure request. Any ambiguity, output loss, lease loss, unexpected match, or inability to type on the emergency keyboard aborts immediately: stop owner, release seizure, disable automatic reseizure, preserve logs.
5. Never test login/FileVault, built-in input, automatic startup, private APIs, or recovery without the emergency keyboard.

## Ordered destructive matrix

For each row, begin stopped, verify the disposable device works physically, start output then lease then task-scoped ownership, type only a predetermined non-secret sequence, induce exactly one fault, and measure from induction until the original physical device resumes. Verify no duplicate/stuck keys, balanced releases, no effect on emergency/built-in/excluded devices, and retained diagnostic reason.

1. Normal stop and repeated stop (idempotence).
2. Grabber clean exit, crash, and `SIGKILL`.
3. Induced grabber heartbeat hang; watchdog must terminate the owner.
4. GUI/XPC lease invalidation and GUI crash.
5. Virtual-output loss and dext crash/termination.
6. Permission revocation while owned.
7. Sleep/wake and logout (not login/FileVault input).
8. Update replacement and rollback, with ownership released before replacement.
9. Uninstall, with ownership released before removal.
10. Repeated acquisition or runtime-owner failures through the configured positive threshold. Below threshold, each failure starts backoff and backoff expiry may request acquisition again if every prerequisite remains true. At threshold the breaker opens: backoff expiry and prerequisite loss/restoration must not request acquisition. Stop/start also leaves a tripped breaker open. Confirm only the explicit operator recovery/reset event closes it, clears the consecutive count, and permits a request when all prerequisites are true.

A row fails if seizure is requested before output plus lease, physical input does not resume, another device is affected, automatic reseizure occurs after breaker trip, recovery cannot be observed, or logs contain secrets. On any failure stop the run; do not tune around it or proceed to built-in testing.

## Evidence and acceptance

Capture monotonic timestamps for readiness, lease, request, ownership, fault, release request, owner death, physical resumption, breaker state, and operator action. Record median/worst observed recovery without claiming a hard guarantee. Acceptance requires every row to pass repeatedly with task ownership visibly gone and the physical device restored; independent safety review must approve evidence. Stage 3 built-in testing remains separately authorized even after acceptance.
