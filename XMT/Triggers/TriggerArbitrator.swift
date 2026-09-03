struct TriggerArbitrator {
    enum State: Equatable { case idle, fnPending, pttActive, chordHoldActive, chordPassthrough }
    private(set) var state: State = .idle
    private var chordHoldOwner: Int64?
    let bareHoldEnabled: Bool

    init(bareHoldEnabled: Bool = true) { self.bareHoldEnabled = bareHoldEnabled }

    @discardableResult
    mutating func receive(_ input: TriggerInput) -> [TriggerEvent] {
        switch (state, input) {
        case (.idle, .fnDown): state = .fnPending
        case (.fnPending, .fnUp): state = .idle
        case (.fnPending, .spaceDown): state = .chordPassthrough; return [.toggleRequested]
        case let (.fnPending, .chordDown(source, action)):
            switch action {
            case .hold:
                state = .chordHoldActive
                chordHoldOwner = source
                return [.pushToTalkBegan]
            case .toggle: state = .chordPassthrough; return [.toggleRequested]
            case .cancel: state = .chordPassthrough; return [.cancelRequested]
            }
        case (.fnPending, .otherKeyDown): state = .chordPassthrough
        case (.fnPending, .holdThresholdElapsed) where bareHoldEnabled:
            state = .pttActive; return [.pushToTalkBegan]
        case (.fnPending, .tapDisabled), (.fnPending, .secureInputInterrupted): state = .idle
        case (.pttActive, .fnUp): state = .idle; return [.pushToTalkEnded]
        case (.pttActive, .spaceDown): return [.toggleRequested]
        case let (.pttActive, .chordDown(_, action)):
            switch action { case .toggle: return [.toggleRequested]; case .cancel: return [.cancelRequested]; case .hold: return [] }
        case (.pttActive, .tapDisabled), (.pttActive, .secureInputInterrupted): state = .idle; return [.pushToTalkEnded]
        // The key that initiated a chord hold owns its release. Releasing Fn
        // first must not end it (the mapper retains the consumed key until key-up).
        case let (.chordHoldActive, .chordUp(source, _)) where source == chordHoldOwner:
            chordHoldOwner = nil
            state = .idle
            return [.pushToTalkEnded]
        case (.chordHoldActive, .tapDisabled), (.chordHoldActive, .secureInputInterrupted):
            chordHoldOwner = nil
            state = .idle
            return [.pushToTalkEnded]
        case (.chordPassthrough, .fnUp), (.chordPassthrough, .tapDisabled), (.chordPassthrough, .secureInputInterrupted): state = .idle
        default: break
        }
        return []
    }
}
