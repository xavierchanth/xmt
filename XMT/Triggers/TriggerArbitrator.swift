struct TriggerArbitrator {
    enum State: Equatable { case idle, fnPending, pttActive, chordHoldActive, chordPassthrough }
    private(set) var state: State = .idle
    let bareHoldEnabled: Bool

    init(bareHoldEnabled: Bool = true) { self.bareHoldEnabled = bareHoldEnabled }

    @discardableResult
    mutating func receive(_ input: TriggerInput) -> [TriggerEvent] {
        switch (state, input) {
        case (.idle, .fnDown): state = .fnPending
        case (.fnPending, .fnUp): state = .idle
        case (.fnPending, .spaceDown): state = .chordPassthrough; return [.toggleRequested]
        case (.fnPending, .chordDown(let action)):
            switch action {
            case .hold: state = .chordHoldActive; return [.pushToTalkBegan]
            case .toggle: state = .chordPassthrough; return [.toggleRequested]
            case .cancel: state = .chordPassthrough; return [.cancelRequested]
            }
        case (.fnPending, .otherKeyDown): state = .chordPassthrough
        case (.fnPending, .holdThresholdElapsed) where bareHoldEnabled:
            state = .pttActive; return [.pushToTalkBegan]
        case (.fnPending, .tapDisabled), (.fnPending, .secureInputInterrupted): state = .idle
        case (.pttActive, .fnUp): state = .idle; return [.pushToTalkEnded]
        case (.pttActive, .spaceDown): return [.toggleRequested]
        case (.pttActive, .chordDown(let action)):
            switch action { case .toggle: return [.toggleRequested]; case .cancel: return [.cancelRequested]; case .hold: return [] }
        case (.pttActive, .tapDisabled), (.pttActive, .secureInputInterrupted): state = .idle; return [.pushToTalkEnded]
        // The key that initiated a chord hold owns its release. Releasing Fn
        // first must not end it (the mapper retains the consumed key until key-up).
        case (.chordHoldActive, .chordUp(.hold)),
             (.chordHoldActive, .tapDisabled), (.chordHoldActive, .secureInputInterrupted):
            state = .idle; return [.pushToTalkEnded]
        case (.chordPassthrough, .fnUp), (.chordPassthrough, .tapDisabled), (.chordPassthrough, .secureInputInterrupted): state = .idle
        default: break
        }
        return []
    }
}
