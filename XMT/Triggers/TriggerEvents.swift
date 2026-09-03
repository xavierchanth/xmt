enum FnChordAction: Equatable { case hold, toggle, cancel }

enum TriggerInput: Equatable {
    case fnDown
    case fnUp
    case chordDown(source: Int64, action: FnChordAction)
    case chordUp(source: Int64, action: FnChordAction)
    case spaceDown // compatibility spelling for the default toggle chord
    case otherKeyDown
    case holdThresholdElapsed
    case tapDisabled
    case secureInputInterrupted
}

enum TriggerEvent: Equatable {
    case pushToTalkBegan
    case pushToTalkEnded
    case toggleRequested
    case cancelRequested
    case secureInputBegan
}
