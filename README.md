# Swapper

Swapper is a macOS menu bar app for moving windows between displays with one configurable global shortcut: `Move window to next screen`. It moves the focused window to the next display with wraparound.

Swapper targets macOS 14+ and uses the Accessibility API to inspect and reposition windows.

## Status

This project is currently maintained for personal use. There are no immediate plans to officially publish it for now.

## Features

- Lives in the menu bar (`LSUIElement`) instead of showing a Dock icon.
- One configurable global shortcut powered by [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts).
- Accessibility permission prompting on launch, plus reminder handling if permissions are missing.
- Launch at Login support through `SMAppService`.
- Native full-screen support for `Move window to next screen`.

## Behavior

Current behavior is documented in more detail in [SWAPPER_BEHAVIOR.md](./SWAPPER_BEHAVIOR.md).

Highlights:

- The shortcut fires on key release.
- Only one window-management action runs at a time.
- Minimized windows are skipped.
- `Move window to next screen` can exit and restore native macOS full-screen when possible.

## Requirements

- macOS 14 or later
- Xcode 15 or later
- Accessibility permission granted to Swapper

## Running Locally

1. Open `Swapper.xcodeproj` in Xcode.
2. Build and run the `Swapper` app target.
3. On first launch, grant Accessibility access when macOS prompts for it.
4. Use the menu bar icon to open `Settings...` and configure the shortcut.

Once running, Swapper appears in the menu bar. The settings window includes:

- `Shortcuts`: records the global hotkey.
- `General`: toggles Launch at Login and shows Accessibility permission status.

## Development

Project layout:

- `Swapper/App`: app entry point and app delegate
- `Swapper/WindowManagement`: window discovery, geometry, and movement logic
- `Swapper/Services`: Accessibility permission and reminder handling
- `Swapper/Settings`: settings UI
- `Swapper/MenuBar`: menu bar menu UI
- `SwapperTests`: unit tests for window geometry

Swift Package dependency:

- `KeyboardShortcuts` `2.4.0`

## Testing

Run tests from Xcode with the `SwapperTests` target, or from the command line:

```bash
xcodebuild test -project Swapper.xcodeproj -scheme Swapper -destination 'platform=macOS'
```

## License

Swapper is licensed under the BSD 3-Clause License. See [LICENSE](./LICENSE).
