import Foundation

/// Presentation model for the Voice binding list. Actions are unique, while the
/// list itself may be empty and its order is a user-interface preference.
struct VoiceActionListModel: Equatable, Sendable {
    private(set) var actions: [VoiceBindingAction] = []

    var availableActions: [VoiceBindingAction] {
        [.holdToTalk, .toggleRecording, .cancel].filter { !actions.contains($0) }
    }

    mutating func replace(with actions: [VoiceBindingAction]) {
        var seen = Set<String>()
        self.actions = actions.filter { seen.insert($0.rawValue).inserted }
    }

    @discardableResult
    mutating func add(_ action: VoiceBindingAction) -> Bool {
        guard !actions.contains(action) else { return false }
        actions.append(action)
        return true
    }

    mutating func remove(_ action: VoiceBindingAction) {
        actions.removeAll { $0 == action }
    }

    mutating func move(_ action: VoiceBindingAction, by offset: Int) {
        guard let source = actions.firstIndex(of: action) else { return }
        let destination = source + offset
        guard actions.indices.contains(destination) else { return }
        actions.swapAt(source, destination)
    }
}
