enum FnChordAction: Equatable { case hold, toggle, cancel }

enum TriggerInput: Equatable {
    case fnDown
    case fnUp
    case chordDown(FnChordAction)
    case chordUp(FnChordAction)
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
