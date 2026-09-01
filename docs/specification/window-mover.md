# Window Mover specification

Window Mover moves the focused window to the next display. This page specifies its behavior as currently implemented in the `XMT` target: the trigger, the permission gate, the preconditions, screen selection, geometry mapping, the reconciliation passes, and native full-screen handling.

This is a specification of released behavior, not a design target. Every claim below was read from the source in `XMT/WindowManagement/`, `XMT/HotKeys/`, `XMT/Services/`, and `XMT/App/`, and from the tests in `XMTTests/WindowGeometryTests.swift`. Where this page and the source disagree, the source is correct. For where the module is going rather than where it is, see [the module model](../architecture/modules.md#window-mover).

Normative language: **MUST**, **MUST NOT**, and **MAY** in this document describe invariants the current implementation upholds, not requirements on future work.

## Trigger

Window Mover registers exactly one global shortcut.

- Shortcut name: `moveToNextScreen`, labelled `Move window to next screen` in Settings.
- Default binding: **Option-Space**.
- The shortcut is user-rebindable on the Window Mover settings page and may be managed by the declarative configuration file. XMT preserves and restores the prior recorder binding when file management begins and ends.
- Window Mover has one persisted enabled setting, which defaults to enabled. Changing it takes effect without restarting XMT.
- When disabled, XMT disables the shortcut registration through KeyboardShortcuts, releasing the active global hot key. Re-enabling reacquires it without restarting XMT. The current implementation leaves the library callback installed and retains an enabled-state guard so a queued or unexpected callback returns before action coordination, permission checks, or window work. KeyboardShortcuts does provide callback removal, but Window Mover does not currently call it.
- The handler fires on **key up**, not key down. A press-and-hold produces one action when the key is released.

Key-up firing means the action is never repeated by key auto-repeat and never fires while the user is still composing a chord.

## Single-flight action

At most one window action runs at a time. While an action is in flight, a further shortcut fire is **dropped**, not queued and not deferred. The in-flight flag is cleared when the action completes, including when it returns early.

Because the full-screen path deliberately waits on macOS transitions, an action can remain in flight for up to several seconds. Shortcut presses during that window have no effect.

The whole action runs on the main actor.

## Accessibility permission gate

The action's first check is the live Accessibility trust state, re-read at each invocation rather than cached from launch.

- XMT does not request Accessibility access merely because the app launched. General and Window Mover settings share one live status presentation, identify Window Mover as the consumer, and offer contextual request and System Settings actions.
- If the shortcut fires without Accessibility access, no window is touched and a reminder alert is shown. The alert offers to open the Accessibility pane of System Settings and re-requests trust.
- The reminder is shown **at most once** while access remains denied. Suppression is lifted when a refresh observes that access has been granted. Accessibility status refreshes whenever the app becomes active, when either shared status presentation appears, and when Window Mover is enabled. General refreshes Launch-at-Login status when it appears and whenever the app becomes active.

## Preconditions and no-op cases

The action returns without moving anything, and without any user-visible error, in each of these cases:

1. Accessibility access is not granted (a reminder MAY be shown, per the gate above).
2. **One display or none.** With `NSScreen.screens.count <= 1` the action is a no-op. There is no next screen and nothing is repositioned.
3. No focused window can be read from the frontmost application — for example when the frontmost app has no window, or when a non-standard window refuses the Accessibility query.
4. The focused window is **minimized**. Minimized windows are skipped; they are not restored, moved, or re-minimized.
5. The window's position or size attribute cannot be read.

Silence is intentional: the shortcut is expected to be pressed in contexts where it does not apply, and an alert per miss would be worse than doing nothing.

Two further early returns exist in the code — failing to resolve a screen for the window's frame, and failing to find that screen in `NSScreen.screens`. Neither is reachable given the checks above: screen resolution returns `nil` only when there are no screens at all, which case 2 has already excluded, and it always returns a member of `NSScreen.screens`. They are internal defensive guards, not observable behavior, and should not be described to users as conditions under which the shortcut does nothing.

## Coordinate space

Accessibility reports window positions with the origin at the **top-left of the primary display** and Y increasing downward; `NSScreen` frames use a bottom-left origin with Y increasing upward. Conversion therefore flips Y around the primary display's top edge. A display arranged above the primary can extend the AppKit desktop union without changing that AX reference; using the union would misplace windows.

## Screen selection

The window's source screen is the screen whose frame has the **largest intersection area** with the window's frame. A window straddling two displays therefore belongs to the display showing more of it.

If no screen intersects the window at all, every candidate ties at zero area and the **first** screen in `NSScreen.screens` order is selected.

The destination is the next screen in `NSScreen.screens` order, wrapping from the last back to the first. The order is macOS's, not a spatial left-to-right ordering, so repeated presses cycle through all displays but not necessarily in physical order.

## Screen frames used for geometry

All geometry — the containment test, proportional mapping, fill, and reconciliation — uses the **full `NSScreen.frame`**, not `visibleFrame`.

The consequence is concrete and intended to be understood before it is changed:

- Proportional ratios are computed against total display bounds, so the menu bar strip and the Dock reservation are part of the mapped area.
- A filled window is given the destination's entire frame, which means it extends under the menu bar and behind the Dock rather than stopping at the usable area.

Some helper parameters in `WindowGeometry` are still named `visibleFrame` from an earlier design; the callers in `WindowMover` pass `screen.frame`. The parameter names are stale, the behavior described here is what runs. Earlier documentation claimed `visibleFrame` was used and was wrong.

## Windowed path

For a window that is not in native full-screen:

1. **Containment test.** The window is considered on-screen if its frame is fully contained in the source screen's frame expanded outward by a **16 pt** tolerance on every side. A window may hang up to 16 pt off any edge and still count as contained.
2. **Contained → proportional mapping.** The window's left offset, top offset, width, and height are expressed as fractions of the source screen frame and re-applied to the destination screen frame. The top-left anchor fraction is preserved, and width and height scale independently with the destination's dimensions, so a window occupying the top-left quarter of one display occupies the top-left quarter of the next.
3. **Not contained → fill.** A window hanging further than the tolerance off its source screen is treated as degenerate and is resized to exactly fill the destination screen frame. Proportional mapping of an already off-screen window would carry it off the destination screen too.
4. The requested size is written first, followed by position, then the realized frame is reconciled. If either required Accessibility write fails, the action returns silently.

The 16 pt tolerance and the fill fallback are covered by unit tests, as are the mapping arithmetic and the corrections below.

## Reconciliation

Applications do not always accept a requested size. They clamp to minimum or maximum sizes, snap to increments, or reshape. Window Mover writes the requested frame and then corrects the origin so the window lands where the user expects even when the size it got is not the size it asked for.

The correction anchors the window to the **nearest edge** of the destination screen frame. Horizontally, whichever of the left or right edge the requested frame was closer to is preserved; vertically, whichever of the top or bottom edge it was closer to. When the two distances on an axis are exactly equal, that axis is **centered** instead. The realized size is kept; only the origin moves.

Reconciliation can run **two correction phases**:

1. **First phase.** Read back the realized frame. Compute the corrected origin from the requested frame, the realized size, and the destination screen frame. Write the origin if it differs from the realized origin.
2. **Second phase, conditionally.** If the realized size differs from the requested size by more than **1 pt** on either axis, write the requested size once more, read the frame back again, recompute the corrected origin, and write it if it differs. The 1 pt threshold absorbs rounding rather than triggering a retry for it.

After the second phase the app's realized result is accepted as final. Window Mover does not loop, does not escalate, and does not report that a window refused its requested size. Reconciliation is skipped entirely if the window's frame cannot be read back.

## Native full-screen path

If the focused window is in native macOS full-screen when the shortcut fires, a different sequence runs and the windowed path is not used at all.

1. **Exit full-screen.** The full-screen attribute is cleared and the window is polled every 100 ms for up to 3 seconds for the transition to complete.
2. **Abort on failure.** If the exit is refused, unreadable, cancelled, or does not confirm within that deadline, the action returns without writing a frame. A timeout is indeterminate because macOS may still be transitioning; XMT does not claim the final full-screen state or display.
3. **Move.** After a 200 ms settle delay, the window is set to fill the destination screen's full frame.
4. **Re-enter full-screen.** After a further 300 ms delay, the full-screen attribute is set and polled every 100 ms for up to 3 seconds.
5. **Fallback.** If re-entry does not confirm within the deadline, the destination screen's full frame is requested again and the action ends. The timeout remains indeterminate; XMT does not claim that the application accepted the frame or abandoned its full-screen transition.

The full-screen path never applies proportional mapping or the reconciliation passes; a full-screen window's target is always the destination's full frame.

### Timing values

The 200 ms and 300 ms delays and the 3 second deadlines are fixed constants, chosen empirically to accommodate the macOS full-screen transition animation. They are not configurable and are not tuned per display. Treat them as implementation constants that may change, not as a contract: only the polling behavior and the abort-on-failure rules above are stable.

## Related documentation

- [Module model](../architecture/modules.md#window-mover) — where this module sits in the intended architecture.
- [App shell](../architecture/app-shell.md#permission-gating) — the general permission-gating and lifecycle rules this module follows.
- [Roadmap](../roadmap/README.md) — known gaps in this module, including the screen-frame question.
