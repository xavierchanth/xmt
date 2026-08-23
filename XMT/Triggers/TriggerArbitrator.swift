struct TriggerArbitrator {
    enum State: Equatable {
        case idle
        case fnPending
        case pttActive
        case chordPassthrough
    }

    private(set) var state: State = .idle

    @discardableResult
    mutating func receive(_ input: TriggerInput) -> [TriggerEvent] {
        switch (state, input) {
        case (.idle, .fnDown):
            state = .fnPending

        case (.fnPending, .fnUp):
            state = .idle
        case (.fnPending, .spaceDown):
            state = .chordPassthrough
            return [.toggleRequested]
        case (.fnPending, .otherKeyDown):
            state = .chordPassthrough
        case (.fnPending, .holdThresholdElapsed):
            state = .pttActive
            return [.pushToTalkBegan]
        case (.fnPending, .tapDisabled), (.fnPending, .secureInputInterrupted):
            state = .idle

        case (.pttActive, .fnUp):
            state = .idle
            return [.pushToTalkEnded]
        case (.pttActive, .spaceDown):
            // Keep PTT active so its begin is balanced when Fn is released.
            return [.toggleRequested]
        case (.pttActive, .tapDisabled), (.pttActive, .secureInputInterrupted):
            state = .idle
            return [.pushToTalkEnded]

        case (.chordPassthrough, .fnUp),
             (.chordPassthrough, .tapDisabled),
             (.chordPassthrough, .secureInputInterrupted):
            state = .idle

        default:
            break
        }
        return []
    }
}
