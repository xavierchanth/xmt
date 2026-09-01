import Foundation

@MainActor
final class WindowActionCoordinator {
    static let shared = WindowActionCoordinator()

    private var actionTask: Task<Void, Never>?
    private var actionID: UUID?
    var isRunningAction: Bool { actionTask != nil }

    private init() {}

    @discardableResult
    func perform(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard actionTask == nil else { return false }
        let id = UUID()
        actionID = id
        actionTask = Task { @MainActor [weak self] in
            await operation()
            guard self?.actionID == id else { return }
            self?.actionTask = nil
            self?.actionID = nil
        }
        return true
    }

    func cancel() {
        actionTask?.cancel()
        actionTask = nil
        actionID = nil
    }
}
