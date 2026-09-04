import KeyboardShortcuts

@MainActor
protocol StandardShortcutBackend: AnyObject {
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void)
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void)
    func removeHandler(for name: KeyboardShortcuts.Name)
    func setEnabled(_ enabled: Bool, for name: KeyboardShortcuts.Name)
}

@MainActor
final class LiveStandardShortcutBackend: StandardShortcutBackend {
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name) {
            MainActor.assumeIsolated { action() }
        }
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name) {
            MainActor.assumeIsolated { action() }
        }
    }

    func removeHandler(for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.removeHandler(for: name)
    }

    func setEnabled(_ enabled: Bool, for name: KeyboardShortcuts.Name) {
        enabled ? KeyboardShortcuts.enable(name) : KeyboardShortcuts.disable(name)
    }
}

struct StandardShortcutRegistration: Equatable {
    let name: KeyboardShortcuts.Name
    let route: InputRoute
    var isEnabled: Bool
}

/// The sole owner of standard shortcut handlers and their active state. Shortcut values retain
/// their established KeyboardShortcuts storage identities while configuration persistence is
/// migrated separately.
@MainActor
final class StandardShortcutProvider {
    typealias Handler = (SemanticActionEvent) -> Void

    private let backend: StandardShortcutBackend
    private let handler: Handler
    private var routing = InputRoutingState()
    private var registrations: [InputSourceID: StandardShortcutRegistration] = [:]
    private var installationEpoch: UInt64 = 0

    convenience init(handler: @escaping Handler) {
        self.init(backend: LiveStandardShortcutBackend(), handler: handler)
    }

    init(backend: StandardShortcutBackend, handler: @escaping Handler) {
        self.backend = backend
        self.handler = handler
    }

    func reconcile(_ replacement: [StandardShortcutRegistration]) throws {
        let snapshot = try InputRouteSnapshot(replacement.map(\.route))
        for registration in registrations.values {
            backend.setEnabled(false, for: registration.name)
            backend.removeHandler(for: registration.name)
        }
        deliver(routing.reconfigure(snapshot))
        registrations.removeAll()
        installationEpoch &+= 1

        for registration in replacement {
            let source = registration.route.source
            let epoch = installationEpoch
            backend.onKeyDown(for: registration.name) { [weak self] in
                self?.receive(.down(source, isRepeat: false), installationEpoch: epoch)
            }
            backend.onKeyUp(for: registration.name) { [weak self] in
                self?.receive(.up(source), installationEpoch: epoch)
            }
            registrations[source] = registration
            backend.setEnabled(registration.isEnabled, for: registration.name)
        }
    }

    func setEnabled(_ enabled: Bool, sources: Set<InputSourceID>,
                    interruption: InputInterruption? = nil) {
        let disablesActiveRegistration = !enabled && sources.contains {
            registrations[$0]?.isEnabled == true
        }
        if disablesActiveRegistration, let interruption {
            deliver(routing.interrupt(interruption))
        }
        for source in sources {
            guard var registration = registrations[source] else { continue }
            registration.isEnabled = enabled
            registrations[source] = registration
            backend.setEnabled(enabled, for: registration.name)
        }
    }

    func stop() {
        deliver(routing.interrupt(.providerLost))
        for registration in registrations.values {
            backend.setEnabled(false, for: registration.name)
            backend.removeHandler(for: registration.name)
        }
        registrations.removeAll()
        installationEpoch &+= 1
        _ = routing.reconfigure(.empty)
    }

    private func receive(_ transition: InputSourceTransition, installationEpoch callbackEpoch: UInt64) {
        guard callbackEpoch == installationEpoch else { return }
        let source: InputSourceID
        switch transition { case .down(let value, _), .up(let value): source = value }
        guard registrations[source]?.isEnabled == true else { return }
        deliver(routing.receive(transition, generation: routing.generation))
    }

    private func deliver(_ events: [SemanticActionEvent]) {
        events.forEach(handler)
    }
}
