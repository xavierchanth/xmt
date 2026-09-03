/// Pure routing and ownership model used by the Voice runtime. A source is the
/// physical registration slot (or Fn gesture), rather than the configured
/// action: this is what lets several bindings target one action safely.
struct VoiceBindingRouter: Equatable {
    enum Action: Equatable { case hold, toggle, cancel }
    struct Source: Hashable, Equatable, Sendable {
        let rawValue: String
        init(_ rawValue: String) { self.rawValue = rawValue }
    }
    enum Input: Equatable {
        case down(Source, Action)
        case up(Source)
        case interrupted
    }
    enum Event: Equatable { case holdBegan, holdEnded, toggleRequested, cancelRequested }

    private(set) var pressed: Set<Source> = []
    private(set) var holdOwner: Source?

    /// Key repeat is deliberately collapsed to one request per physical press.
    mutating func receive(_ input: Input) -> [Event] {
        switch input {
        case let .down(source, action):
            guard pressed.insert(source).inserted else { return [] }
            switch action {
            case .hold:
                guard holdOwner == nil else { return [] }
                holdOwner = source
                return [.holdBegan]
            case .toggle: return [.toggleRequested]
            case .cancel: return [.cancelRequested]
            }
        case let .up(source):
            pressed.remove(source)
            guard holdOwner == source else { return [] }
            holdOwner = nil
            return [.holdEnded]
        case .interrupted:
            pressed.removeAll()
            guard holdOwner != nil else { return [] }
            holdOwner = nil
            return [.holdEnded]
        }
    }

    /// Reconfiguration is an interruption boundary. In particular, a release
    /// from an old registration can never terminate a later hold.
    mutating func reconfigure() -> [Event] { receive(.interrupted) }
}
