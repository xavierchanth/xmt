import XCTest

/// Reproducible pseudo-random source. Seeds are fixed so a failure can be
/// replayed exactly; nothing here touches a clock or a device.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// Tracks what the virtual keyboard would be holding and fails the moment the
/// resolver emits something unbalanced.
private struct BalanceLedger {
    private(set) var keysDown: Set<KeyCode> = []
    private(set) var modifiersDown: Set<KeyModifier> = []

    mutating func apply(_ outputs: [KeyboardOutput], file: StaticString = #filePath, line: UInt = #line) {
        for output in outputs {
            switch output {
            case .keyDown(let key):
                keysDown.insert(key) // repeats legitimately re-press a key that is already down
            case .keyUp(let key):
                XCTAssertTrue(keysDown.remove(key) != nil,
                              "released \(key) that was not down", file: file, line: line)
            case .modifierDown(let modifier):
                XCTAssertTrue(modifiersDown.insert(modifier).inserted,
                              "pressed \(modifier) twice without releasing it", file: file, line: line)
            case .modifierUp(let modifier):
                XCTAssertTrue(modifiersDown.remove(modifier) != nil,
                              "released \(modifier) that was not down", file: file, line: line)
            }
        }
    }

    var isClear: Bool { keysDown.isEmpty && modifiersDown.isEmpty }
}

final class TapHoldResolverPropertyTests: XCTestCase {

    private let devices = [TestDevice.included, TestDevice.second, TestDevice.firmwareManaged]
    private let keys = [TestKey.a, TestKey.s, TestKey.semicolon, TestKey.caps, TestKey.plain, TestKey.otherPlain]
    private let rollovers: [RolloverPolicy] = [.timeoutOnly, .otherKeyPress, .otherKeyRelease]

    private func configuration(rollover: RolloverPolicy) -> KeyboardConfiguration {
        makeConfiguration(hold: 200, quickTap: 120, rollover: rollover,
                          devices: [TestDevice.included, TestDevice.second])
    }

    /// Random but reproducible input, including malformed input: releases with
    /// no press, repeated presses, repeats, backwards timestamps, cancellation
    /// mid-gesture, and events from a device that is out of scope.
    private func randomInputs(seed: UInt64, count: Int, rollover: RolloverPolicy) -> [(KeyboardInput, Int)] {
        var generator = SeededGenerator(seed: seed)
        var inputs: [(KeyboardInput, Int)] = []
        var time = 0
        for _ in 0..<count {
            time += Int.random(in: -40...260, using: &generator)
            let device = devices.randomElement(using: &generator)!
            let key = keys.randomElement(using: &generator)!
            switch Int.random(in: 0..<20, using: &generator) {
            case 0...7:
                inputs.append((.keyDown(device: device, key: key, isRepeat: false), time))
            case 8...14:
                inputs.append((.keyUp(device: device, key: key), time))
            case 15:
                inputs.append((.keyDown(device: device, key: key, isRepeat: true), time))
            case 16:
                inputs.append((.deadline, time))
            case 17:
                inputs.append((.deviceRemoved(device), time))
            case 18:
                inputs.append((.configurationReplaced(configuration(rollover: rollover)), time))
            default:
                inputs.append((.teardown, time))
            }
        }
        return inputs
    }

    func testRandomSequencesNeverEmitAnUnbalancedEvent() {
        for seed in UInt64(1)...UInt64(40) {
            for rollover in rollovers {
                var harness = ResolverHarness(configuration: configuration(rollover: rollover))
                var ledger = BalanceLedger()
                for (input, time) in randomInputs(seed: seed, count: 300, rollover: rollover) {
                    harness.send(input, at: time)
                    ledger.apply(harness.take())
                }
                harness.send(.teardown, at: 1_000_000)
                ledger.apply(harness.take())
                XCTAssertTrue(ledger.isClear,
                              "teardown left \(ledger.keysDown) and \(ledger.modifiersDown) held (seed \(seed), \(rollover))")
            }
        }
    }

    func testTeardownAndRemovalOnlyEverRelease() {
        for seed in UInt64(101)...UInt64(130) {
            var harness = ResolverHarness(configuration: configuration(rollover: .otherKeyRelease))
            for (input, time) in randomInputs(seed: seed, count: 200, rollover: .otherKeyRelease) {
                let isCancellation: Bool
                switch input {
                case .teardown, .deviceRemoved, .configurationReplaced: isCancellation = true
                default: isCancellation = false
                }
                // Let any due timer resolve first so its output is not
                // attributed to the cancellation that follows it.
                harness.advance(to: time)
                _ = harness.take()
                harness.send(input, at: time)
                let outputs = harness.take()
                guard isCancellation else { continue }
                for output in outputs {
                    switch output {
                    case .keyUp, .modifierUp:
                        continue
                    case .keyDown, .modifierDown:
                        XCTFail("cancellation invented \(output) (seed \(seed))")
                    }
                }
            }
        }
    }

    func testExcludedDeviceNeverProducesOutputOrTimer() {
        var harness = ResolverHarness(configuration: configuration(rollover: .otherKeyPress))
        var generator = SeededGenerator(seed: 7)
        var time = 0
        for _ in 0..<500 {
            time += Int.random(in: 0...300, using: &generator)
            let key = keys.randomElement(using: &generator)!
            let input: KeyboardInput = Bool.random(using: &generator)
                ? .keyDown(device: TestDevice.firmwareManaged, key: key, isRepeat: Bool.random(using: &generator))
                : .keyUp(device: TestDevice.firmwareManaged, key: key)
            harness.send(input, at: time)
            XCTAssertFalse(harness.lastResolution.isInScope)
            XCTAssertEqual(harness.take(), [])
            XCTAssertNil(harness.deadline)
        }
    }

    func testARequestedDeadlineIsAlwaysInTheFuture() {
        for seed in UInt64(201)...UInt64(220) {
            var harness = ResolverHarness(configuration: configuration(rollover: .timeoutOnly))
            var latest = Int.min
            for (input, time) in randomInputs(seed: seed, count: 200, rollover: .timeoutOnly) {
                latest = max(latest, time)
                harness.send(input, at: time)
                _ = harness.take()
                if let deadline = harness.deadline {
                    XCTAssertGreaterThan(deadline.milliseconds, latest,
                                         "the resolver asked for a timer that was already due (seed \(seed))")
                }
            }
        }
    }

    func testResolutionIsDeterministicForTheSameSequence() {
        for seed in UInt64(301)...UInt64(320) {
            let inputs = randomInputs(seed: seed, count: 200, rollover: .otherKeyRelease)
            var first = ResolverHarness(configuration: configuration(rollover: .otherKeyRelease))
            var second = ResolverHarness(configuration: configuration(rollover: .otherKeyRelease))
            for (input, time) in inputs {
                first.send(input, at: time)
                second.send(input, at: time)
                XCTAssertEqual(first.take(), second.take(), "seed \(seed)")
            }
        }
    }

    func testBackwardsTimestampsBehaveExactlyLikeTheirClampedSequence() {
        for seed in UInt64(401)...UInt64(420) {
            let inputs = randomInputs(seed: seed, count: 200, rollover: .otherKeyPress)
            var clamped: [(KeyboardInput, Int)] = []
            var latest = Int.min
            for (input, time) in inputs {
                latest = max(latest, time)
                clamped.append((input, latest))
            }
            var raw = ResolverHarness(configuration: configuration(rollover: .otherKeyPress))
            var monotonic = ResolverHarness(configuration: configuration(rollover: .otherKeyPress))
            for index in inputs.indices {
                raw.send(inputs[index].0, at: inputs[index].1)
                monotonic.send(clamped[index].0, at: clamped[index].1)
                XCTAssertEqual(raw.take(), monotonic.take(), "seed \(seed), index \(index)")
            }
        }
    }

    /// Single-key gesture streams have a small closed-form model: quick tap
    /// first, then threshold, then tap. The resolver must agree with it.
    func testSingleKeyGesturesMatchTheTimingModel() {
        let hold = 200
        let quickTap = 120
        for seed in UInt64(501)...UInt64(540) {
            var generator = SeededGenerator(seed: seed)
            var harness = ResolverHarness(configuration: makeConfiguration(hold: hold, quickTap: quickTap))
            var expected: [KeyboardOutput] = []
            var actual: [KeyboardOutput] = []
            var time = 0
            var lastTapEnd: Int?

            for _ in 0..<40 {
                let gap = [0, 1, quickTap - 1, quickTap, quickTap + 1, 400].randomElement(using: &generator)!
                let duration = [0, 1, hold - 1, hold, hold + 1, 900].randomElement(using: &generator)!
                let downAt = time + gap
                let upAt = downAt + duration

                let isQuickTap = lastTapEnd.map { downAt - $0 <= quickTap } ?? false
                if isQuickTap {
                    expected += [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)]
                    lastTapEnd = upAt
                } else if duration >= hold {
                    expected += [.modifierDown(.control), .modifierUp(.control)]
                } else {
                    expected += [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA)]
                    lastTapEnd = upAt
                }

                harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: downAt)
                harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: upAt)
                actual += harness.take()
                time = upAt
            }
            XCTAssertEqual(actual, expected, "seed \(seed)")
        }
    }

    func testRolledPairsPreserveTypedOrderUnderTimeoutOnly() {
        // Two mod-taps tapped in an overlapping roll, both released before the
        // threshold, must produce their tap keys in press order.
        for seed in UInt64(601)...UInt64(640) {
            var generator = SeededGenerator(seed: seed)
            var harness = ResolverHarness(configuration: makeConfiguration(hold: 200, rollover: .timeoutOnly))
            let firstDown = 0
            let secondDown = Int.random(in: 1...50, using: &generator)
            let firstUp = Int.random(in: secondDown...120, using: &generator)
            let secondUp = Int.random(in: firstUp...190, using: &generator)
            harness.send(.keyDown(device: TestDevice.included, key: TestKey.a, isRepeat: false), at: firstDown)
            harness.send(.keyDown(device: TestDevice.included, key: TestKey.s, isRepeat: false), at: secondDown)
            harness.send(.keyUp(device: TestDevice.included, key: TestKey.a), at: firstUp)
            harness.send(.keyUp(device: TestDevice.included, key: TestKey.s), at: secondUp)
            XCTAssertEqual(harness.take(),
                           [.keyDown(TestKey.letterA), .keyUp(TestKey.letterA),
                            .keyDown(TestKey.letterS), .keyUp(TestKey.letterS)],
                           "seed \(seed)")
        }
    }
}
