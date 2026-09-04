/// Stable identity for one compiled-in module. Persistence/configuration code may start with
/// strings, but the routing domain never accepts an empty or whitespace-padded identifier.
struct ModuleID: Hashable, Comparable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private init(validated rawValue: String) { self.rawValue = rawValue }

    static let windowMover = Self(validated: "window-mover")
    static let voiceTranscription = Self(validated: "voice-transcription")
}

/// Stable semantic action identity scoped to one module.
struct ModuleActionID: Hashable, Comparable, Sendable {
    let module: ModuleID
    let rawValue: String

    init?(module: ModuleID, rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        self.module = module
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.module, lhs.rawValue) < (rhs.module, rhs.rawValue)
    }

    private init(module: ModuleID, validated rawValue: String) {
        self.module = module
        self.rawValue = rawValue
    }

    static let moveWindowToNextScreen = Self(module: .windowMover, validated: "move-to-next-screen")
    static let voiceHoldToTalk = Self(module: .voiceTranscription, validated: "hold-to-talk")
    static let voiceToggleRecording = Self(module: .voiceTranscription, validated: "toggle-recording")
    static let voiceCancel = Self(module: .voiceTranscription, validated: "cancel")
    static let voicePasteLatest = Self(module: .voiceTranscription, validated: "paste-latest")
}

/// Provider-scoped physical registration identity. Providers choose stable names that distinguish
/// otherwise identical codes arriving through different physical mechanisms.
struct InputSourceID: Hashable, Comparable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The only valid activation shapes. In particular, a hold cannot also be configured as a
/// one-shot release action through an independent flag.
enum ActionActivation: Equatable, Sendable {
    case press
    case release
    case hold
}

struct InputRoute: Equatable, Sendable {
    let source: InputSourceID
    let action: ModuleActionID
    let activation: ActionActivation
}

enum InputRouteSnapshotError: Error, Equatable, Sendable {
    case duplicateSource(InputSourceID)
}

/// A complete, immutable route table. Unbound values never enter this representation: their
/// absence from the table is the single runtime representation of "not routed".
struct InputRouteSnapshot: Equatable, Sendable {
    static let empty = InputRouteSnapshot(routesBySource: [:])

    private let routesBySource: [InputSourceID: InputRoute]

    init(_ routes: [InputRoute]) throws {
        var result: [InputSourceID: InputRoute] = [:]
        for route in routes {
            guard result.updateValue(route, forKey: route.source) == nil else {
                throw InputRouteSnapshotError.duplicateSource(route.source)
            }
        }
        routesBySource = result
    }

    private init(routesBySource: [InputSourceID: InputRoute]) {
        self.routesBySource = routesBySource
    }

    func route(for source: InputSourceID) -> InputRoute? { routesBySource[source] }

    var routes: [InputRoute] {
        routesBySource.values.sorted { $0.source < $1.source }
    }
}

enum InputInterruption: Equatable, Sendable {
    case reconfigured
    case activationChanged
    case captureBegan
    case permissionLost
    case providerLost
    case secureInput
    case moduleStopped(ModuleID)
}

enum ActionEndReason: Equatable, Sendable {
    case released
    case interrupted(InputInterruption)
}

enum SemanticActionEvent: Equatable, Sendable {
    case invoked(ModuleActionID)
    case began(ModuleActionID)
    case ended(ModuleActionID, reason: ActionEndReason)

    var action: ModuleActionID {
        switch self {
        case .invoked(let action), .began(let action), .ended(let action, _): action
        }
    }
}

enum InputSourceTransition: Equatable, Sendable {
    case down(InputSourceID, isRepeat: Bool)
    case up(InputSourceID)
}

/// Pure routing and ownership reducer. Effectful providers attach the current generation to every
/// callback; replacing or interrupting routes makes already-queued callbacks inert.
struct InputRoutingState: Equatable, Sendable {
    private(set) var snapshot: InputRouteSnapshot
    private(set) var generation: UInt64 = 0
    private(set) var pressedSources: Set<InputSourceID> = []
    private(set) var holdOwners: [ModuleActionID: InputSourceID] = [:]

    init(snapshot: InputRouteSnapshot = .empty) {
        self.snapshot = snapshot
    }

    mutating func receive(_ transition: InputSourceTransition,
                          generation callbackGeneration: UInt64) -> [SemanticActionEvent] {
        guard callbackGeneration == generation else { return [] }

        switch transition {
        case let .down(source, isRepeat):
            guard !isRepeat, let route = snapshot.route(for: source),
                  pressedSources.insert(source).inserted else { return [] }
            switch route.activation {
            case .press:
                return [.invoked(route.action)]
            case .release:
                return []
            case .hold:
                guard holdOwners[route.action] == nil else { return [] }
                holdOwners[route.action] = source
                return [.began(route.action)]
            }

        case let .up(source):
            let wasPressed = pressedSources.remove(source) != nil
            guard wasPressed, let route = snapshot.route(for: source) else { return [] }
            switch route.activation {
            case .press:
                return []
            case .release:
                return [.invoked(route.action)]
            case .hold:
                guard holdOwners[route.action] == source else { return [] }
                holdOwners.removeValue(forKey: route.action)
                return [.ended(route.action, reason: .released)]
            }
        }
    }

    /// Replacement is an interruption boundary. Callers install providers for the returned
    /// generation only after interpreting the balanced end events.
    mutating func reconfigure(_ replacement: InputRouteSnapshot) -> [SemanticActionEvent] {
        let events = endActiveHolds(reason: .reconfigured)
        pressedSources.removeAll()
        snapshot = replacement
        generation &+= 1
        return events
    }

    /// Invalidates queued provider callbacks without changing the desired route snapshot.
    mutating func interrupt(_ reason: InputInterruption) -> [SemanticActionEvent] {
        let events = endActiveHolds(reason: reason)
        pressedSources.removeAll()
        generation &+= 1
        return events
    }

    private mutating func endActiveHolds(reason: InputInterruption) -> [SemanticActionEvent] {
        let actions = holdOwners.keys.sorted()
        holdOwners.removeAll()
        return actions.map { .ended($0, reason: .interrupted(reason)) }
    }
}
import Foundation
