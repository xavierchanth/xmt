# Keyboard Customization DriverKit build-only evidence

This page records what was actually observed while running the build-only, no-live-device stage of the Keyboard Customization feasibility spike. It is an evidence log, not a design and not a status ranking; delivery state stays in the [roadmap](../roadmap/README.md#keyboard-customization-feasibility) and the intended design stays in [Keyboard Customization architecture](../architecture/keyboard-customization.md). Nothing here asserts that Apple will grant an entitlement or that the design works against hardware.

## Scope of this run

The HIDDriverKit virtual keyboard and two inert process boundaries were built. No keyboard was opened, seized, enumerated, or inspected; no extension was submitted for activation; no system extension state was queried or changed. The owner and watchdog compile the shared versioned contract but start no listener or monitoring loop and exit immediately. Real XPC transport, task-scoped IOHID ownership, watchdog enforcement, and virtual-output connection remain unproven.

## Environment observed

| Fact | Observed value |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Xcode | 26.6 (build 17F113) |
| DriverKit SDK | `DriverKit25.5.sdk`, present under `DriverKit.platform` |
| `HIDDriverKit.framework` | Present in the DriverKit SDK, including `IOUserHIDDevice.iig` |
| `iig` interface generator | Present in the default toolchain |
| Code-signing identities | One: `Apple Development: xchan9339@gmail.com (P3UVRT5BG6)`, team `Z36DBP87WY` |
| Developer ID identity | None |
| Provisioning profiles | None installed |
| `DEVELOPMENT_TEAM` in the Xcode project | `Z36DBP87WY` on the shipping app; absent from unsigned feasibility targets |

## Target and identifier boundaries

The spike adds three build-only targets and touches no existing target's product.

| Target | Product | Bundle identifier | Notes |
|---|---|---|---|
| `XMT` | `XMT.app` | `com.xavierchanth.xmt` | Unchanged. Does not embed, depend on, or reference the extension. |
| `XMTTests` | `XMTTests.xctest` | `com.xavierchanth.xmtTests` | Unchanged. |
| `XMTKeyboardOwner` | `XMTKeyboardOwner` | None; command-line product | Universal build-only owner boundary. Exits without opening XPC or HID. |
| `XMTKeyboardWatchdog` | `XMTKeyboardWatchdog` | None; command-line product | Universal build-only watchdog boundary. Contains no monitoring loop. |
| `XMTVirtualKeyboard` | `XMTVirtualKeyboard.dext` | `com.xavierchanth.xmt.virtualkeyboard` | New. Not in the shared `XMT` scheme, not a dependency of any other target, and not copied into the app bundle. |

Because the feasibility products are not embedded, `just build`, `just test`, and `just check` never build them. `just build-dext` builds only the dext; `just build-keyboard-feasibility` explicitly builds all three through the separate `XMTKeyboardFeasibility` scheme.

## Entitlements: requested, not granted

None of the entitlements below has been requested from Apple, granted by Apple, or carried by any provisioning profile on this machine. They are recorded because the design needs them, and the file that lists them says so in its own header comment. Every key was confirmed to be a real key known to the installed toolchain rather than invented for this document.

| Entitlement | Bearer | Why the design needs it |
|---|---|---|
| `com.apple.developer.driverkit` | `XMTVirtualKeyboard.dext` | Permits a DriverKit extension at all. Restricted; requires an Apple grant. |
| `com.apple.developer.driverkit.family.hid.device` | `XMTVirtualKeyboard.dext` | Permits providing a HID device — the virtual keyboard output. Restricted. |
| `com.apple.developer.driverkit.transport.hid` | `XMTVirtualKeyboard.dext` | Permits the HID transport the family is served over. Restricted. |
| `com.apple.developer.driverkit.userclient-access` | Future XMT client/helper target | Names `com.xavierchanth.xmt.virtualkeyboard` as the dext whose user client may be opened. Restricted. It is deliberately absent from both current entitlement files until that client boundary exists. |
| `com.apple.developer.system-extension.install` | `XMT.app` | Would be required for the app to request activation. **Not added.** The app's entitlements file is untouched, because adding it is only meaningful once activation is in scope, and activation is not in scope. |

Apple's approval process for the DriverKit family is a request that Apple may decline; nothing in this repository is evidence that it has been made or answered.

## Build result: go, unsigned only

Building the complete inert feasibility scheme unsigned succeeds.

```
just build-keyboard-feasibility
...
** BUILD SUCCEEDED **
```

Observed properties of the produced bundle:

- `XMTKeyboardOwner` and `XMTKeyboardWatchdog` are universal command-line executables with `arm64` and `x86_64` slices. Each reports wire protocol version `2` through its only diagnostic argument and otherwise exits immediately.
- The shared contract rejects oversized payloads, unsupported versions, incorrect peer roles, cross-session lease use, malformed strict policy, and stale policy revisions in unit tests.
- `iig` generated the interface from `XMTVirtualKeyboardDevice.iig` and the C++ implementation compiled and linked against `DriverKit` and `HIDDriverKit`.
- The product is a universal `XMTVirtualKeyboard.dext` containing `arm64` and `x86_64` slices.
- `codesign -dvvv` on the freshly built product reports `code object is not signed at all`, which is the intended result of `CODE_SIGNING_ALLOWED = NO`.
- The built `Info.plist` has no `IOKitPersonalities` key, confirmed with `plutil -extract IOKitPersonalities`.

The `XMT` app scheme still builds after the project change (`** BUILD SUCCEEDED **`), and the app bundle contains no `Contents/Library/SystemExtensions`.

## Signing result: blocked

Signing the extension for anything the system would load is blocked in this environment, for reasons that are independent of each other:

- **No provisioning profile.** Every entitlement above is restricted. A restricted entitlement only takes effect when it also appears in an embedded provisioning profile issued for the App ID. No profile is installed, and none could be issued without the Apple grant that has not been sought.
- **No Developer ID identity.** `codesign --sign "Developer ID Application"` fails with `no identity found`. Distributing a system extension outside development requires Developer ID signing and notarization.
- **Development signing was not completed.** Signing with the one available `Apple Development` identity blocked on an interactive keychain authorization and was abandoned rather than prompting. It was not retried, and no conclusion about it is recorded here. Even had it succeeded, the missing profile above would still prevent the entitlements from taking effect.

An ad-hoc signature (`codesign --sign -`) can be applied and will list the entitlement keys, but it carries `TeamIdentifier=not set` and `Signature=adhoc`. That is a local artifact of `codesign` not validating entitlement authorization; it is not approval and the system would not load it.

**Verdict: go for unsigned compilation and packaging, blocked for signing.** The build-only gate's compile and package questions are answered yes; its signing question is answered no, and it stays no until an Apple entitlement grant and a matching provisioning profile exist. The external-keyboard stage cannot be reached from here.

## What is deliberately inert

The products cannot activate, by construction and not merely by convention:

- The bundle declares no `IOKitPersonalities`, so nothing can match it and the system cannot load it even if it were signed and installed.
- The extension is not embedded in `XMT.app`, so it cannot be discovered for activation.
- No code in the app requests activation, and the app carries no system-extension entitlement.
- Neither helper is embedded, installed, registered with launchd, or reachable from the app. Both have an immediate-exit entry point and no XPC listener.
- The driver class implements only `init`, `free`, `Start`, `Stop`, `newDeviceDescription`, and `newReportDescriptor`. It sends no report and opens nothing.

Adding personalities, embedding the extension, or adding activation code are each separate changes that need the authorization the roadmap describes.

## Related documentation

- [Keyboard Customization architecture](../architecture/keyboard-customization.md) — the design this spike tests.
- [Roadmap](../roadmap/README.md#keyboard-customization-feasibility) — the gates and current delivery state.
