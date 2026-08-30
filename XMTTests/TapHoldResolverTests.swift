import XCTest

// MARK: - Shared fixtures

/// Opaque tokens. These are not hardware key codes; the resolver only compares
/// them, and no test here touches a device.
enum TestKey {
    static let a = KeyCode(1)
    static let s = KeyCode(2)
    static let semicolon = KeyCode(3)
    static let caps = KeyCode(4)
    static let escape = KeyCode(10)
    static let letterA = KeyCode(11)
    static let letterS = KeyCode(12)
    static let letterSemicolon = KeyCode(13)
    static let plain = KeyCode(20)
    static let otherPlain = KeyCode(21)
}

enum TestDevice {
    static let included = KeyboardDeviceID("included-keyboard")
    static let second = KeyboardDeviceID("second-keyboard")
    static let firmwareManaged = KeyboardDeviceID("firmware-managed-keyboard")
}

func makeConfiguration(hold: Int = 200,
                       quickTap: Int = 0,
                       rollover: RolloverPolicy = .timeoutOnly,
                       devices: [KeyboardDeviceID] = [TestDevice.included],
                       extraKeys: [KeyCode: KeyBehavior] = [:]) -> KeyboardConfiguration {
    let timing = KeyTiming(holdMilliseconds: hold, quickTapMilliseconds: quickTap, rollover: rollover)
    var keys: [KeyCode: KeyBehavior] = [
        TestKey.a: KeyBehavior(tap: TestKey.letterA, hold: .control),
        TestKey.s: KeyBehavior(tap: TestKey.letterS, hold: .shift),
        TestKey.semicolon: KeyBehavior(tap: TestKey.letterSemicolon, hold: .control),
        TestKey.caps: KeyBehavior(tap: TestKey.escape, hold: .hyper),
    ]
    for (key, behavior) in extraKeys { keys[key] = behavior }
    let policy = DeviceKeyboardPolicy(timing: timing, keys: keys)
    return KeyboardConfiguration(devices: Dictionary(uniqueKeysWithValues: devices.map { ($0, policy) }))
}

/// Drives the resolver the way the module would: it honours the deadline the
/// resolver asks for, firing it before any later event. It owns no clock.
struct ResolverHarness {
    private(set) var resolver: TapHoldResolver
    private(set) var outputs: [KeyboardOutput] = []
    private(set) var deadline: KeyboardInstant?
    private(set) var lastResolution = KeyboardResolution()

    init(configuration: KeyboardConfiguration) {
        resolver = TapHoldResolver(configuration: configuration)
    }

    mutating func send(_ input: KeyboardInput, at milliseconds: Int) {
        fireDeadlines(upTo: milliseconds)
        apply(input, at: KeyboardInstant(milliseconds: milliseconds))
    }

    mutating func advance(to milliseconds: Int) { fireDeadlines(upTo: milliseconds) }

    mutating func take() -> [KeyboardOutput] { defer { outputs = [] }; return outputs }

    private mutating func fireDeadlines(upTo milliseconds: Int) {
        var guardrail = 0
        while let due = deadline, due.milliseconds <= milliseconds, guardrail < 64 {
            guardrail += 1
            apply(.deadline, at: due)
            if deadline == due { break }
        }
    }

    private mutating func apply(_ input: KeyboardInput, at instant: KeyboardInstant) {
        let resolution = resolver.receive(input, at: instant)
        lastResolution = resolution
        outputs += resolution.outputs
        deadline = resolution.deadline
    }
}

// MARK: - Tests

final class TapHoldResolverTests: XCTestCase {

    // MARK: Tap and hold timing

    func testModTapBelowThresholdEmitsTapKeyOnRelease() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        XCTAssertEqual(harness.take(), [], "an undecided mod-tap emits nothing while it is down")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 199)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)])
    }

    func testModTapAtThresholdResolvesAsHold() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        XCTAssertEqual(harness.deadline, KeyboardInstant(milliseconds: 200))
        harness.advance(to: 200)
        XCTAssertEqual(harness.take(), [.modifierDown(.control)])
        XCTAssertNil(harness.deadline, "a resolved hold leaves no timer running")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 400)
        XCTAssertEqual(harness.take(), [.modifierUp(.control)])
    }

    func testReleaseAfterThresholdWithoutTimerStillResolvesAsHold() {
        var resolver = TapHoldResolver(configuration: makeConfiguration(hold: 200))
        _ = resolver.receive(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false),
                             at: KeyboardInstant(milliseconds: 0))
        // The caller never delivered the deadline; a late release must not tap.
        let resolution = resolver.receive(.keyUp(device: TestDevice.included, key: TestKey.a),
                                          at: KeyboardInstant(milliseconds: 500))
        XCTAssertEqual(resolution.outputs, [.modifierDown(.control), .modifierUp(.control)])
    }

    func testPerKeyTimingOverrideBeatsDevicePolicy() {
        let slow = KeyBehavior(tap: TestKey.letterA, hold: .control,
                               timing: KeyTiming(holdMilliseconds: 500))
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 100, extraKeys: [TestKey.a: slow]))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        XCTAssertEqual(harness.deadline, KeyboardInstant(milliseconds: 500))
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 300)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)],
                       "300ms is a hold under the device policy but a tap under the key override")
    }

    func testNoTimerIsRequestedWhileNothingIsPending() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 0)
        XCTAssertNil(harness.deadline)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 10)
        XCTAssertNil(harness.deadline)
    }

    // MARK: Hyper Caps

    func testHyperCapsTapEmitsEscape() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.caps), at: 50)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.escape), .keyUp(TestKey.escape)])
    }

    func testHyperCapsHoldFormsAllFourModifiersAndReleasesInReverse() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        harness.advance(to: 200)
        XCTAssertEqual(harness.take(), [.modifierDown(.control), .modifierDown(.shift),
                                        .modifierDown(.option), .modifierDown(.command)])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.caps), at: 900)
        XCTAssertEqual(harness.take(), [.modifierUp(.command), .modifierUp(.option),
                                        .modifierUp(.shift), .modifierUp(.control)])
    }

    func testHyperHoldPassesOtherKeysThroughWhileHeld() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        harness.advance(to: 200)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 250)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 260)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.plain), .keyUp(TestKey.plain)])
    }

    // MARK: Quick tap

    func testQuickTapTypesTheTapKeyHeldInsteadOfArmingTheHold() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, quickTap: 150))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 50)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)])

        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 100)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA)], "the second press types immediately")
        XCTAssertNil(harness.deadline, "quick tap arms no hold timer")
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: true), at: 600)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA)], "auto-repeat repeats the tap key")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 700)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.letterA)])
    }

    func testQuickTapWindowExpiryFallsBackToNormalHoldResolution() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, quickTap: 150))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 50)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 201)
        XCTAssertEqual(harness.take(), [], "201ms is outside the 150ms quick-tap window")
        harness.advance(to: 401)
        XCTAssertEqual(harness.take(), [.modifierDown(.control)])
    }

    func testQuickTapIsDisabledWhenTheWindowIsZero() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, quickTap: 0))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 10)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 20)
        XCTAssertEqual(harness.take(), [])
        XCTAssertEqual(harness.deadline, KeyboardInstant(milliseconds: 220))
    }

    func testQuickTapChainsFromTheMostRecentRelease() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, quickTap: 150))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 20)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 40)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 60)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 80)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA)])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 90)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.letterA)])
    }

    // MARK: Rollover

    func testTimeoutOnlyRolloverPreservesTypedOrder() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .timeoutOnly))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 30)
        XCTAssertEqual(harness.take(), [], "the rolled key waits so it cannot outrun the pending tap")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 60)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 90)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA),
                                        .keyDown(TestKey.plain), .keyUp(TestKey.plain)])
    }

    func testTimeoutOnlyRolloverStillHoldsWhenTheThresholdPasses() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .timeoutOnly))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 30)
        harness.advance(to: 200)
        XCTAssertEqual(harness.take(), [.modifierDown(.control), .keyDown(TestKey.plain)],
                       "the buffered key replays after the hold forms")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 250)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 260)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.plain), .modifierUp(.control)])
    }

    func testOtherKeyPressRolloverResolvesHoldImmediately() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .otherKeyPress))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 30)
        XCTAssertEqual(harness.take(), [.modifierDown(.control), .keyDown(TestKey.plain)])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 40)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 50)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.plain), .modifierUp(.control)])
    }

    func testOtherKeyReleaseRolloverHoldsWhenTheNestedKeyCompletes() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .otherKeyRelease))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 30)
        XCTAssertEqual(harness.take(), [])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 60)
        XCTAssertEqual(harness.take(), [.modifierDown(.control), .keyDown(TestKey.plain), .keyUp(TestKey.plain)])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 70)
        XCTAssertEqual(harness.take(), [.modifierUp(.control)])
    }

    func testOtherKeyReleaseRolloverTapsWhenTheModTapIsRolledOffFirst() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .otherKeyRelease))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 30)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 60)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 90)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA),
                                        .keyDown(TestKey.plain), .keyUp(TestKey.plain)])
    }

    func testKeyPressedBeforeTheModTapIsNeverStrandedDown() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .timeoutOnly))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 0)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 10)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 20)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.plain)],
                       "a key that went down before the mod-tap releases without waiting")
    }

    func testNestedModTapsBothResolveAsHolds() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .timeoutOnly))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.s, isRepeat: false), at: 50)
        harness.advance(to: 250)
        XCTAssertEqual(harness.take(), [.modifierDown(.control), .modifierDown(.shift)])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.s), at: 300)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 310)
        XCTAssertEqual(harness.take(), [.modifierUp(.shift), .modifierUp(.control)])
    }

    // MARK: Modifiers held by more than one key

    func testTwoKeysHoldingTheSameModifierEmitOneDownAndOneUp() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .otherKeyPress))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.advance(to: 200)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.semicolon, isRepeat: false), at: 210)
        harness.advance(to: 410)
        XCTAssertEqual(harness.take(), [.modifierDown(.control)], "Control is reference counted")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 500)
        XCTAssertEqual(harness.take(), [], "Control stays down while the other key still holds it")
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.semicolon), at: 510)
        XCTAssertEqual(harness.take(), [.modifierUp(.control)])
    }

    func testTwoDevicesResolveIndependentlyAndShareModifierAccounting() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200,
                                                                       devices: [TestDevice.included, TestDevice.second]))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.second, key: TestKey.semicolon, isRepeat: false), at: 10)
        harness.advance(to: 210)
        XCTAssertEqual(harness.take(), [.modifierDown(.control)])
        harness.send(.keyUp(device: TestDevice.second, key: TestKey.semicolon), at: 300)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 310)
        XCTAssertEqual(harness.take(), [.modifierUp(.control)])
    }

    // MARK: Repeat and malformed input

    func testRepeatOfAnUndecidedModTapEmitsNothingAndKeepsItPending() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 5_000))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: true), at: 500)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: true), at: 600)
        XCTAssertEqual(harness.take(), [])
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 700)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)])
    }

    func testRepeatOfAResolvedHoldEmitsNothing() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.advance(to: 200)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: true), at: 300)
        XCTAssertEqual(harness.take(), [])
    }

    func testUnmappedKeyRepeatsAreForwardedAndReleaseOnce() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: true), at: 500)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 600)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.plain), .keyDown(TestKey.plain), .keyUp(TestKey.plain)])
    }

    func testUnmatchedReleaseEmitsNothing() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 10)
        XCTAssertEqual(harness.take(), [])
    }

    func testDuplicateDownWithoutReleaseDoesNotDoubleEmit() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 10)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.plain), at: 20)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.plain), .keyUp(TestKey.plain)])
    }

    func testOutOfOrderTimestampsAreClampedRatherThanTrapped() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 1_000)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 400)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)],
                       "a backwards timestamp is clamped to now, so the key reads as a tap")
    }

    func testBackwardsDeadlineDeliveryDoesNotResolveEarly() {
        var resolver = TapHoldResolver(configuration: makeConfiguration(hold: 200))
        _ = resolver.receive(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false),
                             at: KeyboardInstant(milliseconds: 1_000))
        let early = resolver.receive(.deadline, at: KeyboardInstant(milliseconds: 0))
        XCTAssertEqual(early.outputs, [])
        XCTAssertEqual(early.deadline, KeyboardInstant(milliseconds: 1_200))
    }

    // MARK: Device scope

    func testUnlistedDeviceIsReportedOutOfScopeAndKeepsNoState() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.keyDown(device: TestDevice.firmwareManaged, key: TestKey.a, isRepeat: false), at: 0)
        XCTAssertFalse(harness.lastResolution.isInScope)
        XCTAssertEqual(harness.take(), [])
        XCTAssertNil(harness.deadline, "an excluded device never arms a timer")
        harness.send(.keyUp(device: TestDevice.firmwareManaged, key: TestKey.a), at: 500)
        XCTAssertFalse(harness.lastResolution.isInScope)
        XCTAssertEqual(harness.take(), [])
    }

    func testIncludedDeviceEventsAreReportedInScope() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 0)
        XCTAssertTrue(harness.lastResolution.isInScope)
    }

    // MARK: Cancellation, replacement, teardown

    func testDeviceRemovalCancelsAnUndecidedModTapWithoutInventingATap() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.deviceRemoved(TestDevice.included), at: 50)
        XCTAssertEqual(harness.take(), [])
        XCTAssertNil(harness.deadline)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 60)
        XCTAssertEqual(harness.take(), [], "the cancelled gesture produces no late tap")
    }

    func testDeviceRemovalReleasesHeldModifiersAndDownKeys() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        harness.advance(to: 200)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 210)
        _ = harness.take()
        harness.send(.deviceRemoved(TestDevice.included), at: 300)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.plain),
                                        .modifierUp(.command), .modifierUp(.option),
                                        .modifierUp(.shift), .modifierUp(.control)])
    }

    func testDeviceRemovalLeavesTheOtherDeviceUntouched() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200,
                                                                       devices: [TestDevice.included, TestDevice.second]))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.second, key: TestKey.s, isRepeat: false), at: 10)
        harness.send(.deviceRemoved(TestDevice.included), at: 20)
        XCTAssertEqual(harness.take(), [])
        XCTAssertEqual(harness.deadline, KeyboardInstant(milliseconds: 210))
        harness.advance(to: 210)
        XCTAssertEqual(harness.take(), [.modifierDown(.shift)])
    }

    func testDeviceRemovalDropsBufferedRolloverWithoutOutput() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .timeoutOnly))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.plain, isRepeat: false), at: 30)
        harness.send(.deviceRemoved(TestDevice.included), at: 40)
        harness.advance(to: 1_000)
        XCTAssertEqual(harness.take(), [])
    }

    func testDeviceRemovalClearsQuickTapHistory() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, quickTap: 150))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 20)
        harness.send(.deviceRemoved(TestDevice.included), at: 30)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 40)
        XCTAssertEqual(harness.take(), [], "a reconnected device does not inherit a quick tap")
        XCTAssertEqual(harness.deadline, KeyboardInstant(milliseconds: 240))
    }

    func testConfigurationReplacementReleasesEverythingAndAdoptsTheNewScope() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.advance(to: 200)
        _ = harness.take()
        harness.send(.configurationReplaced(makeConfiguration(hold: 200, devices: [TestDevice.second])), at: 250)
        XCTAssertEqual(harness.take(), [.modifierUp(.control)], "the old hold is released, not stranded")
        XCTAssertNil(harness.deadline)

        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 260)
        XCTAssertFalse(harness.lastResolution.isInScope, "the previously included device is now excluded")
        harness.send(.keyDown(device: TestDevice.second, key: TestKey.a, isRepeat: false), at: 270)
        XCTAssertTrue(harness.lastResolution.isInScope)
    }

    func testConfigurationReplacementCancelsPendingWithoutInventingATap() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.configurationReplaced(makeConfiguration(hold: 300)), at: 50)
        XCTAssertEqual(harness.take(), [])
        XCTAssertNil(harness.deadline)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 60)
        harness.advance(to: 360)
        XCTAssertEqual(harness.take(), [.modifierDown(.control)], "the replacement's timing governs the next gesture")
    }

    func testConfigurationReplacementDropsQuickTapHistory() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, quickTap: 150))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 20)
        harness.send(.configurationReplaced(makeConfiguration(hold: 200, quickTap: 150)), at: 30)
        _ = harness.take()
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 40)
        XCTAssertEqual(harness.take(), [])
    }

    func testReplacementWithAnEmptyConfigurationStopsTransforming() {
        var harness = ResolverHarness(configuration: makeConfiguration())
        harness.send(.configurationReplaced(.excludingEverything), at: 0)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 10)
        XCTAssertFalse(harness.lastResolution.isInScope)
        XCTAssertEqual(harness.take(), [])
    }

    func testTeardownReleasesEverythingAndRequestsNoTimer() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200,
                                                                       devices: [TestDevice.included, TestDevice.second]))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        harness.advance(to: 200)
        harness.send(.keyDown(device: TestDevice.second, key: TestKey.plain, isRepeat: false), at: 210)
        harness.send(.keyDown(device: TestDevice.second, key: TestKey.s, isRepeat: false), at: 220)
        _ = harness.take()
        harness.send(.teardown, at: 300)
        XCTAssertEqual(harness.take(), [.modifierUp(.command), .modifierUp(.option),
                                        .modifierUp(.shift), .modifierUp(.control),
                                        .keyUp(TestKey.plain)],
                       "devices are released in identity order; the undecided mod-tap is dropped")
        XCTAssertNil(harness.deadline)
    }

    func testTeardownIsIdempotent() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.advance(to: 200)
        _ = harness.take()
        harness.send(.teardown, at: 300)
        XCTAssertEqual(harness.take(), [.modifierUp(.control)])
        harness.send(.teardown, at: 310)
        XCTAssertEqual(harness.take(), [])
        harness.send(.deviceRemoved(TestDevice.included), at: 320)
        XCTAssertEqual(harness.take(), [])
    }

    func testResolverKeepsWorkingAfterTeardown() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.teardown, at: 10)
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 20)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: 30)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)])
    }

    func testDeadlineForAnAlreadyCancelledGestureIsHarmless() {
        var harness = ResolverHarness(configuration: makeConfiguration(hold: 200))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: 0)
        harness.send(.teardown, at: 50)
        var resolver = harness.resolver
        // A timer the caller had already scheduled fires after cancellation.
        let late = resolver.receive(.deadline, at: KeyboardInstant(milliseconds: 200))
        XCTAssertEqual(late.outputs, [])
        XCTAssertNil(late.deadline)
    }

    // MARK: Configuration validation

    func testValidConfigurationValidates() throws {
        XCTAssertEqual(try makeConfiguration().validated(), makeConfiguration())
    }

    func testNonPositiveHoldThresholdIsRejected() {
        let configuration = makeConfiguration(hold: 0)
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? KeyboardConfigurationError,
                           .nonPositiveHoldThreshold(device: TestDevice.included, key: nil))
        }
    }

    func testNegativeQuickTapWindowIsRejected() {
        let configuration = makeConfiguration(quickTap: -1)
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? KeyboardConfigurationError,
                           .negativeQuickTapWindow(device: TestDevice.included, key: nil))
        }
    }

    func testPerKeyOverrideIsValidatedToo() {
        let configuration = makeConfiguration(
            extraKeys: [TestKey.a: KeyBehavior(tap: TestKey.letterA, hold: .control,
                                               timing: KeyTiming(holdMilliseconds: -5))])
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? KeyboardConfigurationError,
                           .nonPositiveHoldThreshold(device: TestDevice.included, key: TestKey.a))
        }
    }

    func testBehaviorWithNeitherTapNorHoldIsRejected() {
        let configuration = makeConfiguration(extraKeys: [TestKey.a: KeyBehavior()])
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? KeyboardConfigurationError,
                           .behaviorDoesNothing(device: TestDevice.included, key: TestKey.a))
        }
    }

    func testEmptyDeviceIdentityIsRejected() {
        let configuration = makeConfiguration(devices: [KeyboardDeviceID("")])
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? KeyboardConfigurationError, .emptyDeviceIdentity)
        }
    }

    func testEmptyConfigurationValidatesAndTransformsNothing() throws {
        XCTAssertEqual(try KeyboardConfiguration.excludingEverything.validated().devices, [:])
    }

    // MARK: Behaviors other than mod-tap

    func testPlainRemapEmitsImmediatelyWithNoHoldTimer() {
        var harness = ResolverHarness(configuration: makeConfiguration(
            extraKeys: [TestKey.caps: KeyBehavior(tap: TestKey.escape)]))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        XCTAssertEqual(harness.take(), [.keyDown(TestKey.escape)])
        XCTAssertNil(harness.deadline)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.caps), at: 10)
        XCTAssertEqual(harness.take(), [.keyUp(TestKey.escape)])
    }

    func testHoldOnlyKeyFormsItsModifiersImmediately() {
        var harness = ResolverHarness(configuration: makeConfiguration(
            extraKeys: [TestKey.caps: KeyBehavior(hold: .hyper)]))
        harness.send(.keyDown(device: TestDevice.included, key: TestKey.caps, isRepeat: false), at: 0)
        XCTAssertEqual(harness.take(), [.modifierDown(.control), .modifierDown(.shift),
                                        .modifierDown(.option), .modifierDown(.command)])
        XCTAssertNil(harness.deadline)
        harness.send(.keyUp(device: TestDevice.included, key: TestKey.caps), at: 10)
        XCTAssertEqual(harness.take(), [.modifierUp(.command), .modifierUp(.option),
                                        .modifierUp(.shift), .modifierUp(.control)])
    }
}
