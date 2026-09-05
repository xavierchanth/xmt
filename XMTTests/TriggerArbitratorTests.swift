import XCTest
import KeyboardShortcuts

final class TriggerArbitratorTests: XCTestCase {
    func testIdleFnDownBecomesPendingWithoutOutput() {
        assertSequence([.fnDown], state: .fnPending, events: [])
    }

    func testIdleInputsOtherThanFnDownAreIgnored() {
        for input in inputs.filter({ $0 != .fnDown }) { assertSequence([input], state: .idle, events: []) }
    }

    func testPendingFnUpMakesBareTapInert() {
        assertSequence([.fnDown, .fnUp], state: .idle, events: [])
    }

    func testPendingOtherKeyEntersChordPassthroughWithoutOutput() {
        assertSequence([.fnDown, .otherKeyDown], state: .chordPassthrough, events: [])
    }

    func testChordPassthroughIgnoresKeysAndThreshold() {
        assertSequence([.fnDown, .otherKeyDown, .spaceDown, .otherKeyDown, .holdThresholdElapsed],
               state: .chordPassthrough, events: [])
    }

    func testChordPassthroughFnUpReturnsIdle() {
        assertSequence([.fnDown, .otherKeyDown, .fnUp], state: .idle, events: [])
    }

    func testPendingThresholdBeginsPushToTalk() {
        assertSequence([.fnDown, .holdThresholdElapsed], state: .pttActive, events: [.pushToTalkBegan])
    }

    func testThresholdAfterFnReleaseCannotBeginPushToTalk() {
        assertSequence([.fnDown, .fnUp, .holdThresholdElapsed], state: .idle, events: [])
    }

    func testActiveFnUpBalancesBeginWithEnd() {
        assertSequence([.fnDown, .holdThresholdElapsed, .fnUp], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testPendingFnSpaceRequestsToggleAndPreventsPushToTalk() {
        assertSequence([.fnDown, .spaceDown, .holdThresholdElapsed], state: .chordPassthrough,
               events: [.toggleRequested])
    }

    func testActiveFnSpaceRequestsToggleButRetainsActiveState() {
        assertSequence([.fnDown, .holdThresholdElapsed, .spaceDown], state: .pttActive,
               events: [.pushToTalkBegan, .toggleRequested])
    }

    // Contract: the Voice module may latch recording on toggle and ignore the
    // balanced PTT end for recording semantics; this trigger layer stays balanced.
    func testActiveFnSpaceStillBalancesOnReleaseForVoiceModuleToInterpret() {
        assertSequence([.fnDown, .holdThresholdElapsed, .spaceDown, .fnUp], state: .idle,
               events: [.pushToTalkBegan, .toggleRequested, .pushToTalkEnded])
    }

    func testTapDisabledWhilePendingCancelsGesture() {
        assertSequence([.fnDown, .tapDisabled], state: .idle, events: [])
    }

    func testSecureInputWhilePendingCancelsGesture() {
        assertSequence([.fnDown, .secureInputInterrupted], state: .idle, events: [])
    }

    func testTapDisabledWhileActiveSynthesizesEnd() {
        assertSequence([.fnDown, .holdThresholdElapsed, .tapDisabled], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testSecureInputWhileActiveSynthesizesEnd() {
        assertSequence([.fnDown, .holdThresholdElapsed, .secureInputInterrupted], state: .idle,
               events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testInterruptionWhileChordPassthroughReturnsIdleWithoutOutput() {
        assertSequence([.fnDown, .otherKeyDown, .secureInputInterrupted], state: .idle, events: [])
    }

    func testDisableWhileChordPassthroughReturnsIdleWithoutOutput() {
        assertSequence([.fnDown, .otherKeyDown, .tapDisabled], state: .idle, events: [])
    }

    func testRepeatedAndOutOfOrderInputsNeverEmitUnmatchedEnd() {
        var machine = TriggerArbitrator()
        var balance = 0
        for input in inputs + inputs + inputs.reversed() {
            for event in machine.receive(input) {
                if event == .pushToTalkBegan { balance += 1 }
                if event == .pushToTalkEnded { balance -= 1 }
                XCTAssertGreaterThanOrEqual(balance, 0)
                XCTAssertLessThanOrEqual(balance, 1)
            }
        }
        XCTAssertEqual(balance, 0)
    }

    func testPhysicalMapperConsumesSpaceDownAndMatchingUp() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        XCTAssertEqual(mapper.keyDown(code: 49, isRepeat: false),
                       .init(input: .chordDown(source: 49, action: .toggle), consumesEvent: true))
        XCTAssertEqual(mapper.keyUp(code: 49), .init(input: .chordUp(source: 49, action: .toggle), consumesEvent: true))
    }

    func testPhysicalMapperConsumesSpaceUpAfterFnRelease() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        _ = mapper.fnChanged(isDown: false)
        XCTAssertTrue(mapper.keyUp(code: 49).consumesEvent)
    }

    func testPhysicalMapperInterruptionClearsConsumedSpace() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        mapper.interrupt()
        XCTAssertFalse(mapper.keyUp(code: 49).consumesEvent)
        XCTAssertFalse(mapper.fnIsDown)
    }

    func testPhysicalMapperConsumesSpaceRepeatWithoutAnotherInput() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        XCTAssertEqual(mapper.keyDown(code: 49, isRepeat: true),
                       .init(input: nil, consumesEvent: true))
    }

    func testPhysicalMapperDoesNotConsumeUnrelatedLaterSpaceUp() {
        var mapper = FnPhysicalEventMapper()
        _ = mapper.fnChanged(isDown: true)
        _ = mapper.keyDown(code: 49, isRepeat: false)
        mapper.interrupt()
        XCTAssertFalse(mapper.keyUp(code: 49).consumesEvent)
        XCTAssertFalse(mapper.keyUp(code: 49).consumesEvent)
    }

    func testConfiguredDefaultChordsCoexistWithBareHold() {
        assertSequence([.fnDown, .chordDown(source: 49, action: .toggle), .chordUp(source: 49, action: .toggle), .fnUp], state: .idle, events: [.toggleRequested])
        assertSequence([.fnDown, .chordDown(source: 53, action: .cancel), .chordUp(source: 53, action: .cancel), .fnUp], state: .idle, events: [.cancelRequested])
        assertSequence([.fnDown, .holdThresholdElapsed, .chordDown(source: 53, action: .cancel), .fnUp], state: .idle,
                       events: [.pushToTalkBegan, .cancelRequested, .pushToTalkEnded])
    }

    func testChordHoldInitiatingKeyOwnsReleaseWhenFnReleasedFirst() {
        assertSequence([.fnDown, .chordDown(source: 53, action: .hold), .fnUp], state: .chordHoldActive,
                       events: [.pushToTalkBegan])
        assertSequence([.fnDown, .chordDown(source: 53, action: .hold), .fnUp, .chordUp(source: 53, action: .hold)], state: .idle,
                       events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testBindingRouterMultiplexesSourcesAndCollapsesRepeats() {
        var router = VoiceBindingRouter()
        let first = VoiceBindingRouter.Source("slot.0")
        let second = VoiceBindingRouter.Source("slot.1")
        XCTAssertEqual(router.receive(.down(first, .toggle)), [.toggleRequested])
        XCTAssertEqual(router.receive(.down(first, .toggle)), [])
        XCTAssertEqual(router.receive(.up(first)), [])
        XCTAssertEqual(router.receive(.down(second, .toggle)), [.toggleRequested])
    }

    func testBindingRouterHoldReleaseIsOwnedAndReconfigurationIsSafe() {
        var router = VoiceBindingRouter()
        let owner = VoiceBindingRouter.Source("slot.0")
        let other = VoiceBindingRouter.Source("slot.1")
        XCTAssertEqual(router.receive(.down(owner, .hold)), [.holdBegan])
        XCTAssertEqual(router.receive(.down(other, .hold)), [])
        XCTAssertEqual(router.receive(.up(other)), [])
        XCTAssertEqual(router.receive(.up(owner)), [.holdEnded])
        XCTAssertEqual(router.receive(.down(owner, .hold)), [.holdBegan])
        XCTAssertEqual(router.reconfigure(), [.holdEnded])
        XCTAssertEqual(router.receive(.up(owner)), [])
    }

    func testFnChordHoldIgnoresEveryNonOwningReleaseInArbitraryOrder() {
        assertSequence([
            .fnDown,
            .chordDown(source: 53, action: .hold),
            .chordDown(source: 49, action: .hold),
            .chordUp(source: 49, action: .hold),
            .chordUp(source: 36, action: .toggle),
            .fnUp,
            .chordUp(source: 53, action: .hold)
        ], state: .idle, events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testBindingRouterGenerationMakesQueuedCallbacksHarmless() {
        var router = VoiceBindingRouter()
        let oldGeneration = router.generation
        let owner = VoiceBindingRouter.Source("slot.0")
        XCTAssertEqual(router.reconfigure(), [])
        XCTAssertEqual(router.receive(.down(owner, .hold), generation: oldGeneration), [])
        XCTAssertEqual(router.receive(.up(owner), generation: oldGeneration), [])
        XCTAssertNil(router.holdOwner)
        XCTAssertTrue(router.pressed.isEmpty)
        XCTAssertEqual(router.receive(.down(owner, .hold), generation: router.generation), [.holdBegan])
    }

    func testBindingRouterInterruptionEndsHoldExactlyOnce() {
        var router = VoiceBindingRouter()
        let source = VoiceBindingRouter.Source("fn.escape")
        XCTAssertEqual(router.receive(.down(source, .hold)), [.holdBegan])
        XCTAssertEqual(router.receive(.interrupted), [.holdEnded])
        XCTAssertEqual(router.receive(.interrupted), [])
    }

    func testConfiguredFnHoldBalancesOnKeyUpAndInterruption() {
        var mapper = FnPhysicalEventMapper(chords: [53: .hold])
        _ = mapper.fnChanged(isDown: true)
        XCTAssertEqual(mapper.keyDown(code: 53, isRepeat: false).input, .chordDown(source: 53, action: .hold))
        XCTAssertNil(mapper.keyDown(code: 53, isRepeat: true).input)
        XCTAssertEqual(mapper.keyUp(code: 53).input, .chordUp(source: 53, action: .hold))
        assertSequence([.fnDown, .chordDown(source: 53, action: .hold), .chordUp(source: 53, action: .hold)], state: .idle,
                       events: [.pushToTalkBegan, .pushToTalkEnded])
        assertSequence([.fnDown, .chordDown(source: 53, action: .hold), .tapDisabled], state: .idle,
                       events: [.pushToTalkBegan, .pushToTalkEnded])
    }

    func testInputRouteSnapshotRejectsDuplicatePhysicalOwner() throws {
        let source = inputSource("standard.command-k")
        XCTAssertThrowsError(try InputRouteSnapshot([
            .init(source: source, action: action("window", "move"), activation: .release),
            .init(source: source, action: action("voice", "toggle"), activation: .press)
        ])) { error in
            XCTAssertEqual(error as? InputRouteSnapshotError, .duplicateSource(source))
        }
    }

    func testInputRoutingSeparatesPressReleaseAndHoldActivation() throws {
        let press = inputSource("standard.press")
        let release = inputSource("standard.release")
        let hold = inputSource("standard.hold")
        let pressAction = action("voice", "toggle")
        let releaseAction = action("window", "move")
        let holdAction = action("voice", "hold")
        var state = InputRoutingState(snapshot: try .init([
            .init(source: press, action: pressAction, activation: .press),
            .init(source: release, action: releaseAction, activation: .release),
            .init(source: hold, action: holdAction, activation: .hold)
        ]))
        let generation = state.generation

        XCTAssertEqual(state.receive(.down(press, isRepeat: false), generation: generation), [.invoked(pressAction)])
        XCTAssertEqual(state.receive(.up(press), generation: generation), [])
        XCTAssertEqual(state.receive(.down(release, isRepeat: false), generation: generation), [])
        XCTAssertEqual(state.receive(.up(release), generation: generation), [.invoked(releaseAction)])
        XCTAssertEqual(state.receive(.down(hold, isRepeat: false), generation: generation), [.began(holdAction)])
        XCTAssertEqual(state.receive(.up(hold), generation: generation), [.ended(holdAction, reason: .released)])
    }

    func testInputRoutingCollapsesRepeatsAndDuplicateDown() throws {
        let source = inputSource("standard.toggle")
        let target = action("voice", "toggle")
        var state = InputRoutingState(snapshot: try .init([
            .init(source: source, action: target, activation: .press)
        ]))
        let generation = state.generation

        XCTAssertEqual(state.receive(.down(source, isRepeat: true), generation: generation), [])
        XCTAssertEqual(state.receive(.down(source, isRepeat: false), generation: generation), [.invoked(target)])
        XCTAssertEqual(state.receive(.down(source, isRepeat: false), generation: generation), [])
        XCTAssertEqual(state.receive(.down(source, isRepeat: true), generation: generation), [])
        XCTAssertEqual(state.receive(.up(source), generation: generation), [])
    }

    func testInputRoutingHoldIsOwnedByItsBeginningSource() throws {
        let first = inputSource("standard.hold.0")
        let second = inputSource("standard.hold.1")
        let target = action("voice", "hold")
        var state = InputRoutingState(snapshot: try .init([
            .init(source: first, action: target, activation: .hold),
            .init(source: second, action: target, activation: .hold)
        ]))
        let generation = state.generation

        XCTAssertEqual(state.receive(.down(first, isRepeat: false), generation: generation), [.began(target)])
        XCTAssertEqual(state.receive(.down(second, isRepeat: false), generation: generation), [])
        XCTAssertEqual(state.receive(.up(second), generation: generation), [])
        XCTAssertEqual(state.receive(.up(first), generation: generation), [.ended(target, reason: .released)])
    }

    func testInputRoutingSupportsIndependentHoldsAndEndsDeterministically() throws {
        let voiceSource = inputSource("standard.voice-hold")
        let otherSource = inputSource("standard.other-hold")
        let voiceAction = action("voice", "hold")
        let otherAction = action("other", "hold")
        var state = InputRoutingState(snapshot: try .init([
            .init(source: voiceSource, action: voiceAction, activation: .hold),
            .init(source: otherSource, action: otherAction, activation: .hold)
        ]))
        let generation = state.generation

        XCTAssertEqual(state.receive(.down(voiceSource, isRepeat: false), generation: generation), [.began(voiceAction)])
        XCTAssertEqual(state.receive(.down(otherSource, isRepeat: false), generation: generation), [.began(otherAction)])
        XCTAssertEqual(state.interrupt(.providerLost), [
            .ended(otherAction, reason: .interrupted(.providerLost)),
            .ended(voiceAction, reason: .interrupted(.providerLost))
        ])
        XCTAssertTrue(state.holdOwners.isEmpty)
        XCTAssertTrue(state.pressedSources.isEmpty)
    }

    func testInputRoutingReconfigurationBalancesHoldAndRejectsStaleCallbacks() throws {
        let oldSource = inputSource("standard.old")
        let newSource = inputSource("standard.new")
        let target = action("voice", "hold")
        var state = InputRoutingState(snapshot: try .init([
            .init(source: oldSource, action: target, activation: .hold)
        ]))
        let oldGeneration = state.generation
        XCTAssertEqual(state.receive(.down(oldSource, isRepeat: false), generation: oldGeneration), [.began(target)])

        XCTAssertEqual(state.reconfigure(try .init([
            .init(source: newSource, action: target, activation: .hold)
        ])), [.ended(target, reason: .interrupted(.reconfigured))])
        XCTAssertEqual(state.receive(.up(oldSource), generation: oldGeneration), [])
        XCTAssertEqual(state.receive(.down(oldSource, isRepeat: false), generation: oldGeneration), [])
        XCTAssertEqual(state.receive(.down(newSource, isRepeat: false), generation: state.generation), [.began(target)])
    }

    func testInputRoutingUnchangedReloadPreservesActiveHold() throws {
        let source = inputSource("standard.voice.hold")
        let route = InputRoute(source: source, action: .voiceHoldToTalk, activation: .hold,
                               chord: .key(key: "space", modifiers: ["control"]))
        let snapshot = try InputRouteSnapshot([route])
        var state = InputRoutingState(snapshot: snapshot)
        let generation = state.generation

        XCTAssertEqual(state.receive(.down(source, isRepeat: false), generation: generation), [.began(.voiceHoldToTalk)])
        XCTAssertEqual(state.reconfigure(snapshot), [])
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.receive(.up(source), generation: generation), [.ended(.voiceHoldToTalk, reason: .released)])
    }

    func testInputRoutingScopedInterruptionLeavesOtherHoldActive() throws {
        let window = inputSource("standard.window.hold")
        let voice = inputSource("standard.voice.hold")
        var state = InputRoutingState(snapshot: try .init([
            .init(source: window, action: .moveWindowToNextScreen, activation: .hold),
            .init(source: voice, action: .voiceHoldToTalk, activation: .hold)
        ]))
        let generation = state.generation
        _ = state.receive(.down(window, isRepeat: false), generation: generation)
        _ = state.receive(.down(voice, isRepeat: false), generation: generation)

        XCTAssertEqual(state.interrupt(sources: [window], reason: .moduleStopped(.windowMover)), [
            .ended(.moveWindowToNextScreen, reason: .interrupted(.moduleStopped(.windowMover)))
        ])
        XCTAssertEqual(state.receive(.up(voice), generation: generation), [
            .ended(.voiceHoldToTalk, reason: .released)
        ])
    }

    func testInputRoutingIdentifiersRejectEmptyAndPaddedValues() {
        XCTAssertNil(ModuleID(""))
        XCTAssertNil(ModuleID(" voice"))
        XCTAssertNil(InputSourceID("standard "))
        XCTAssertNil(ModuleActionID(module: module("voice"), rawValue: ""))
        XCTAssertNotNil(ModuleActionID(module: module("voice"), rawValue: "toggle"))
    }

    func testBuiltInModuleCatalogDeclaresCompleteActionOwnership() {
        let catalog = XMTModuleCatalog.builtIn
        #if XMT_VOICE
        XCTAssertEqual(catalog.descriptors.map(\.id), [.voiceTranscription, .windowMover])
        XCTAssertEqual(catalog.descriptor(for: .windowMover)?.permissions, [.accessibility])
        XCTAssertEqual(
            Set(catalog.descriptor(for: .voiceTranscription)?.actions ?? []),
            [.voiceHoldToTalk, .voiceToggleRecording, .voiceCancel, .voicePasteLatest]
        )
        XCTAssertTrue(XMTBuildFeatures.voice)
        #else
        XCTAssertFalse(XMTBuildFeatures.voice)
        XCTAssertEqual(catalog.descriptors.map(\.id), [.windowMover])
        XCTAssertNil(catalog.descriptor(for: .voiceTranscription))
        XCTAssertEqual(catalog.descriptor(for: .windowMover)?.actions, [.moveWindowToNextScreen])
        #endif
    }

    func testModuleDescriptorRejectsCrossModuleAndDuplicateActions() throws {
        XCTAssertThrowsError(try XMTModuleDescriptor(
            id: .windowMover,
            displayName: "Window Mover",
            permissions: [],
            actions: [.voiceCancel]
        )) { error in
            XCTAssertEqual(
                error as? XMTModuleCatalogError,
                .actionBelongsToDifferentModule(action: .voiceCancel, expected: .windowMover)
            )
        }
        XCTAssertThrowsError(try XMTModuleDescriptor(
            id: .windowMover,
            displayName: "Window Mover",
            permissions: [],
            actions: [.moveWindowToNextScreen, .moveWindowToNextScreen]
        )) { error in
            XCTAssertEqual(error as? XMTModuleCatalogError, .duplicateAction(.moveWindowToNextScreen))
        }
    }

    func testModuleCatalogRejectsDuplicateModuleIdentity() throws {
        let descriptor = try XMTModuleDescriptor(
            id: .windowMover,
            displayName: "Window Mover",
            permissions: [.accessibility],
            actions: [.moveWindowToNextScreen]
        )
        XCTAssertThrowsError(try XMTModuleCatalog([descriptor, descriptor])) { error in
            XCTAssertEqual(error as? XMTModuleCatalogError, .duplicateModule(.windowMover))
        }
    }

    @MainActor
    func testStandardShortcutProviderRoutesReleaseAndSuppressesDuplicateDown() throws {
        let backend = FakeStandardShortcutBackend()
        let source = inputSource("standard.window")
        let name = KeyboardShortcuts.Name("test.standard.window")
        var events: [SemanticActionEvent] = []
        let provider = StandardShortcutProvider(backend: backend) { events.append($0) }
        try provider.reconcile([.init(
            name: name,
            route: .init(source: source, action: .moveWindowToNextScreen, activation: .release),
            isEnabled: true
        )])

        backend.keyDown(name)
        backend.keyDown(name)
        backend.keyUp(name)

        XCTAssertEqual(events, [.invoked(.moveWindowToNextScreen)])
    }

    @MainActor
    func testStandardShortcutProviderInterruptsHoldAndAcceptsLaterCallbacks() throws {
        let backend = FakeStandardShortcutBackend()
        let source = inputSource("standard.voice.hold")
        let name = KeyboardShortcuts.Name("test.standard.voice.hold")
        var events: [SemanticActionEvent] = []
        let provider = StandardShortcutProvider(backend: backend) { events.append($0) }
        try provider.reconcile([.init(
            name: name,
            route: .init(source: source, action: .voiceHoldToTalk, activation: .hold),
            isEnabled: true
        )])

        backend.keyDown(name)
        let staleDown = backend.downHandlers[name]?.last
        provider.setEnabled(false, sources: [source], interruption: .captureBegan)
        backend.keyUp(name)
        provider.setEnabled(true, sources: [source])
        staleDown?()
        backend.keyDown(name)
        backend.keyUp(name)

        XCTAssertEqual(events, [
            .began(.voiceHoldToTalk),
            .ended(.voiceHoldToTalk, reason: .interrupted(.captureBegan)),
            .began(.voiceHoldToTalk),
            .ended(.voiceHoldToTalk, reason: .released)
        ])
    }

    @MainActor
    func testStandardShortcutProviderReconcileDisableBalancesUnchangedRoute() throws {
        let backend = FakeStandardShortcutBackend()
        let source = inputSource("standard.voice.hold.reconcile-disable")
        let name = KeyboardShortcuts.Name("test.standard.voice.hold.reconcile-disable")
        let route = InputRoute(source: source, action: .voiceHoldToTalk, activation: .hold)
        var events: [SemanticActionEvent] = []
        let provider = StandardShortcutProvider(backend: backend) { events.append($0) }
        try provider.reconcile([.init(name: name, route: route, isEnabled: true)])
        backend.keyDown(name)

        try provider.reconcile([.init(name: name, route: route, isEnabled: false)])

        XCTAssertEqual(events, [
            .began(.voiceHoldToTalk),
            .ended(.voiceHoldToTalk, reason: .interrupted(.activationChanged))
        ])
        XCTAssertEqual(backend.enabled[name], false)
    }

    @MainActor
    func testStandardShortcutProviderReentrantActivationUpdateWinsAfterReconcile() throws {
        let backend = FakeStandardShortcutBackend()
        let source = inputSource("standard.voice.hold.reentrant")
        let name = KeyboardShortcuts.Name("test.standard.voice.hold.reentrant")
        var provider: StandardShortcutProvider!
        provider = StandardShortcutProvider(backend: backend) { event in
            if case .ended = event {
                provider.setEnabled(false, sources: [source], interruption: .activationChanged)
            }
        }
        try provider.reconcile([.init(
            name: name,
            route: .init(source: source, action: .voiceHoldToTalk, activation: .hold,
                         chord: .key(key: "a", modifiers: ["control"])),
            isEnabled: true
        )])
        backend.keyDown(name)

        try provider.reconcile([.init(
            name: name,
            route: .init(source: source, action: .voiceHoldToTalk, activation: .hold,
                         chord: .key(key: "b", modifiers: ["control"])),
            isEnabled: true
        )])

        XCTAssertEqual(backend.enabled[name], false)
        backend.keyDown(name)
    }

    @MainActor
    func testStandardShortcutProviderRejectsRemovedHandlerCallbacks() throws {
        let backend = FakeStandardShortcutBackend()
        let oldSource = inputSource("standard.old")
        let newSource = inputSource("standard.new")
        let oldName = KeyboardShortcuts.Name("test.standard.old")
        let newName = KeyboardShortcuts.Name("test.standard.new")
        var events: [SemanticActionEvent] = []
        let provider = StandardShortcutProvider(backend: backend) { events.append($0) }
        try provider.reconcile([.init(
            name: oldName,
            route: .init(source: oldSource, action: .moveWindowToNextScreen, activation: .press),
            isEnabled: true
        )])
        let removedHandler = backend.downHandlers[oldName]?.last

        try provider.reconcile([.init(
            name: newName,
            route: .init(source: newSource, action: .voicePasteLatest, activation: .press),
            isEnabled: true
        )])
        removedHandler?()
        backend.keyDown(newName)

        XCTAssertEqual(events, [.invoked(.voicePasteLatest)])
    }

    @MainActor
    func testStandardShortcutProviderChangedChordEndsHoldOnceAndRejectsOldCallbacks() throws {
        let backend = FakeStandardShortcutBackend()
        let source = inputSource("standard.voice.hold.0")
        let name = KeyboardShortcuts.Name("test.standard.voice.hold.changed")
        var events: [SemanticActionEvent] = []
        let provider = StandardShortcutProvider(backend: backend) { events.append($0) }
        let oldRoute = InputRoute(source: source, action: .voiceHoldToTalk, activation: .hold,
                                  chord: .key(key: "a", modifiers: ["control"]))
        try provider.reconcile([.init(name: name, route: oldRoute, isEnabled: true)])
        backend.keyDown(name)
        let staleUp = backend.upHandlers[name]?.last

        let newRoute = InputRoute(source: source, action: .voiceHoldToTalk, activation: .hold,
                                  chord: .key(key: "b", modifiers: ["control"]))
        try provider.reconcile([.init(name: name, route: newRoute, isEnabled: true)])
        staleUp?()
        backend.keyUp(name)

        XCTAssertEqual(events, [
            .began(.voiceHoldToTalk),
            .ended(.voiceHoldToTalk, reason: .interrupted(.reconfigured))
        ])
    }

    @MainActor
    func testStandardShortcutProviderRemovedHoldEndsOnceAndRejectsOldRelease() throws {
        let backend = FakeStandardShortcutBackend()
        let source = inputSource("standard.voice.hold.removed")
        let name = KeyboardShortcuts.Name("test.standard.voice.hold.removed")
        var events: [SemanticActionEvent] = []
        let provider = StandardShortcutProvider(backend: backend) { events.append($0) }
        try provider.reconcile([.init(
            name: name,
            route: .init(source: source, action: .voiceHoldToTalk, activation: .hold,
                         chord: .key(key: "a", modifiers: ["control"])),
            isEnabled: true
        )])
        backend.keyDown(name)
        let staleUp = backend.upHandlers[name]?.last

        try provider.reconcile([])
        staleUp?()

        XCTAssertEqual(events, [
            .began(.voiceHoldToTalk),
            .ended(.voiceHoldToTalk, reason: .interrupted(.reconfigured))
        ])
    }

    private let inputs: [TriggerInput] = [
        .fnDown, .fnUp, .spaceDown, .chordDown(source: 49, action: .toggle), .chordUp(source: 49, action: .toggle), .otherKeyDown, .holdThresholdElapsed,
        .tapDisabled, .secureInputInterrupted
    ]

    private func assertSequence(
        _ inputs: [TriggerInput],
        state: TriggerArbitrator.State,
        events expected: [TriggerEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var machine = TriggerArbitrator()
        let events = inputs.flatMap { machine.receive($0) }
        XCTAssertEqual(machine.state, state, file: file, line: line)
        XCTAssertEqual(events, expected, file: file, line: line)
    }

    private func module(_ value: String) -> ModuleID {
        guard let result = ModuleID(value) else { fatalError("invalid test module") }
        return result
    }

    private func action(_ moduleValue: String, _ actionValue: String) -> ModuleActionID {
        guard let result = ModuleActionID(module: module(moduleValue), rawValue: actionValue) else {
            fatalError("invalid test action")
        }
        return result
    }

    private func inputSource(_ value: String) -> InputSourceID {
        guard let result = InputSourceID(value) else { fatalError("invalid test input source") }
        return result
    }
}

@MainActor
private final class FakeStandardShortcutBackend: StandardShortcutBackend {
    private(set) var downHandlers: [KeyboardShortcuts.Name: [@MainActor () -> Void]] = [:]
    private(set) var upHandlers: [KeyboardShortcuts.Name: [@MainActor () -> Void]] = [:]
    private(set) var enabled: [KeyboardShortcuts.Name: Bool] = [:]

    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        downHandlers[name, default: []].append(action)
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        upHandlers[name, default: []].append(action)
    }

    func removeHandler(for name: KeyboardShortcuts.Name) {
        enabled[name] = false
    }

    func setEnabled(_ enabled: Bool, for name: KeyboardShortcuts.Name) {
        self.enabled[name] = enabled
    }

    func keyDown(_ name: KeyboardShortcuts.Name) {
        guard enabled[name] == true else { return }
        downHandlers[name]?.last?()
    }

    func keyUp(_ name: KeyboardShortcuts.Name) {
        guard enabled[name] == true else { return }
        upHandlers[name]?.last?()
    }
}
