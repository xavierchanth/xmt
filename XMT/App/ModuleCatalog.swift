import Foundation

enum XMTModulePermission: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case inputMonitoring
    case microphone
}

enum XMTModuleCatalogError: Error, Equatable, Sendable {
    case emptyDisplayName(ModuleID)
    case actionBelongsToDifferentModule(action: ModuleActionID, expected: ModuleID)
    case duplicateAction(ModuleActionID)
    case duplicateModule(ModuleID)
}

/// Immutable metadata for one compiled-in module. Runtime closures deliberately live outside
/// this value so the catalog remains a pure, testable description of the app boundary.
struct XMTModuleDescriptor: Equatable, Sendable {
    let id: ModuleID
    let displayName: String
    let permissions: Set<XMTModulePermission>
    let actions: [ModuleActionID]

    init(id: ModuleID, displayName: String, permissions: Set<XMTModulePermission>,
         actions: [ModuleActionID]) throws {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty, normalizedDisplayName == displayName else {
            throw XMTModuleCatalogError.emptyDisplayName(id)
        }
        var seen: Set<ModuleActionID> = []
        for action in actions {
            guard action.module == id else {
                throw XMTModuleCatalogError.actionBelongsToDifferentModule(action: action, expected: id)
            }
            guard seen.insert(action).inserted else {
                throw XMTModuleCatalogError.duplicateAction(action)
            }
        }
        self.id = id
        self.displayName = displayName
        self.permissions = permissions
        self.actions = actions
    }
}

struct XMTModuleCatalog: Equatable, Sendable {
    private let descriptorsByID: [ModuleID: XMTModuleDescriptor]

    init(_ descriptors: [XMTModuleDescriptor]) throws {
        var result: [ModuleID: XMTModuleDescriptor] = [:]
        for descriptor in descriptors {
            guard result.updateValue(descriptor, forKey: descriptor.id) == nil else {
                throw XMTModuleCatalogError.duplicateModule(descriptor.id)
            }
        }
        descriptorsByID = result
    }

    private init(validated descriptors: [XMTModuleDescriptor]) {
        var result: [ModuleID: XMTModuleDescriptor] = [:]
        for descriptor in descriptors { result[descriptor.id] = descriptor }
        descriptorsByID = result
    }

    var descriptors: [XMTModuleDescriptor] {
        descriptorsByID.values.sorted { $0.id < $1.id }
    }

    func descriptor(for id: ModuleID) -> XMTModuleDescriptor? { descriptorsByID[id] }

    static let builtIn = XMTModuleCatalog(validated: [
        XMTModuleDescriptor(
            validatedID: .windowMover,
            displayName: "Window Mover",
            permissions: [.accessibility],
            actions: [.moveWindowToNextScreen]
        ),
        XMTModuleDescriptor(
            validatedID: .voiceTranscription,
            displayName: "Voice Transcription",
            permissions: [.accessibility, .inputMonitoring, .microphone],
            actions: [.voiceHoldToTalk, .voiceToggleRecording, .voiceCancel, .voicePasteLatest]
        )
    ])
}

private extension XMTModuleDescriptor {
    init(validatedID id: ModuleID, displayName: String, permissions: Set<XMTModulePermission>,
         actions: [ModuleActionID]) {
        self.id = id
        self.displayName = displayName
        self.permissions = permissions
        self.actions = actions
    }
}
