import Foundation

@MainActor
final class WindowActionCoordinator {
    static let shared = WindowActionCoordinator()

    private var isRunningAction = false

    private init() {}

    func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard !isRunningAction else { return }

        isRunningAction = true

        Task { @MainActor in
            defer { isRunningAction = false }
            await operation()
        }
    }
}
