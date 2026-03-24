# Swapper Behavior

## Shortcuts

- `Move window to next screen` moves the focused window forward through `NSScreen.screens` with wraparound.
- `Rotate desktops` moves every eligible window one screen forward through the same display order.
- Both shortcuts fire on key release.
- Only one window-management action can run at a time. Additional shortcut presses are ignored while an action is in progress.

## Accessibility

- Swapper requests Accessibility access at launch if it is missing.
- If a shortcut is used without Accessibility access, Swapper shows a reminder once and suppresses further reminders until the Accessibility permission state changes.

## Move Window To Next Screen

- Minimized windows are skipped.
- Normal windowed windows use the source and destination `visibleFrame` values for geometry mapping.
- The mapping preserves the window's top-left anchor and scales width and height proportionally.
- A window that is more than `16pt` outside its source `visibleFrame` is treated as degenerate and resized to exactly fill the destination `visibleFrame`.
- After a move, Swapper reads back the realized size and performs one correction pass to preserve the nearest destination edge. Tied axes stay centered.
- If the app clamps or reshapes the window, Swapper accepts the app's realized result after that single correction pass.

## Native Full-Screen

- `Move window to next screen` supports windows that start in native macOS full-screen.
- Swapper exits native full-screen, targets the destination display directly, and then attempts to re-enter native full-screen.
- If re-entering native full-screen fails, the window remains on the destination display and fills the destination `visibleFrame` without re-entering native full-screen.
- `Rotate desktops` excludes native full-screen windows.

## Rotate Desktops

- `Rotate desktops` is the user-facing name for the old bulk rotation action.
- Eligible windows move independently; windows are not grouped by app or desktop.
- Minimized windows are skipped.
- Obvious floating, dialog, and sheet subroles are skipped when Accessibility exposes them.
- Overlap resolution, focus restoration, and z-order management are out of scope.
