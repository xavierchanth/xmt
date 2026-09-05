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
    private var installationEpochs: [InputSourceID: UInt64] = [:]

    convenience init(handler: @escaping Handler) {
        self.init(backend: LiveStandardShortcutBackend(), handler: handler)
    }

    init(backend: StandardShortcutBackend, handler: @escaping Handler) {
        self.backend = backend
        self.handler = handler
    }

    func reconcile(_ replacement: [StandardShortcutRegistration]) throws {
        let snapshot = try InputRouteSnapshot(replacement.map(\.route))
        let replacements = Dictionary(uniqueKeysWithValues: replacement.map { ($0.route.source, $0) })
        let previousRegistrations = registrations
        let staleSources = Set(registrations.compactMap { source, registration in
            guard let replacement = replacements[source] else { return source }
            return replacement.name == registration.name && replacement.route == registration.route
                ? nil : source
        })
        let newSources = Set(replacements.keys).subtracting(registrations.keys)
        let enabledChangedSources = Set<InputSourceID>(replacements.compactMap { source, replacement in
            guard let previous = registrations[source], previous.isEnabled != replacement.isEnabled else {
                return nil
            }
            return source
        })
        let changedSources = staleSources.union(newSources).union(enabledChangedSources)
        let disabledSources = Set(enabledChangedSources.filter {
            previousRegistrations[$0]?.isEnabled == true && replacements[$0]?.isEnabled == false
        })

        for source in changedSources {
            guard let registration = registrations[source] else { continue }
            backend.setEnabled(false, for: registration.name)
            backend.removeHandler(for: registration.name)
            installationEpochs[source, default: 0] &+= 1
        }
        var events = routing.reconfigure(snapshot)
        events += routing.interrupt(sources: disabledSources, reason: .activationChanged)
        registrations = replacements

        for source in changedSources {
            guard let registration = replacements[source] else { continue }
            install(registration)
        }
        deliver(events)
    }

    func setEnabled(_ enabled: Bool, sources: Set<InputSourceID>,
                    interruption: InputInterruption? = nil) {
        let changedSources = Set(sources.filter { registrations[$0]?.isEnabled != enabled })
        let disabledSources: Set<InputSourceID> = enabled ? [] : changedSources
        let events = interruption.map {
            routing.interrupt(sources: disabledSources, reason: $0)
        } ?? []
        for source in sources {
            guard var registration = registrations[source] else { continue }
            guard registration.isEnabled != enabled else { continue }
            backend.setEnabled(false, for: registration.name)
            backend.removeHandler(for: registration.name)
            installationEpochs[source, default: 0] &+= 1
            registration.isEnabled = enabled
            registrations[source] = registration
            install(registration)
        }
        deliver(events)
    }

    func stop() {
        deliver(routing.interrupt(.providerLost))
        for registration in registrations.values {
            backend.setEnabled(false, for: registration.name)
            backend.removeHandler(for: registration.name)
        }
        registrations.removeAll()
        for source in Array(installationEpochs.keys) { installationEpochs[source, default: 0] &+= 1 }
        _ = routing.reconfigure(.empty)
    }

    private func receive(_ transition: InputSourceTransition, installationEpoch callbackEpoch: UInt64) {
        let source: InputSourceID
        switch transition { case .down(let value, _), .up(let value): source = value }
        guard callbackEpoch == installationEpochs[source] else { return }
        guard registrations[source]?.isEnabled == true else { return }
        deliver(routing.receive(transition, generation: routing.generation))
    }

    private func install(_ registration: StandardShortcutRegistration) {
        let source = registration.route.source
        let epoch = installationEpochs[source, default: 0]
        installationEpochs[source] = epoch
        backend.onKeyDown(for: registration.name) { [weak self] in
            self?.receive(.down(source, isRepeat: false), installationEpoch: epoch)
        }
        backend.onKeyUp(for: registration.name) { [weak self] in
            self?.receive(.up(source), installationEpoch: epoch)
        }
        backend.setEnabled(registration.isEnabled, for: registration.name)
    }

    private func deliver(_ events: [SemanticActionEvent]) {
        events.forEach(handler)
    }
}
