enum TriggerInput: Equatable {
    case fnDown
    case fnUp
    case spaceDown
    case otherKeyDown
    case holdThresholdElapsed
    case tapDisabled
    case secureInputInterrupted
}

enum TriggerEvent: Equatable {
    case pushToTalkBegan
    case pushToTalkEnded
    case toggleRequested
}
