import Foundation

/// One durable transcript history row. This type is the whole persistence surface: the repository
/// writes exactly these fields and nothing else, so anything absent here can never reach disk.
enum TranscriptSource: String, Equatable, Sendable { case live, recovery, legacy }

struct TranscriptHistoryEntry: Equatable, Sendable {
    /// Stable identity of the entry. Derived from the committing session, never random at write
    /// time, so replaying an interrupted commit inserts the same row rather than a duplicate.
    let id: UUID
    let recordedAt: Date
    let text: String
    let localeIdentifier: String
    var source: TranscriptSource = .live
}

/// Bounded-history retention. Both bounds are total: a policy always resolves to usable limits.
struct TranscriptRetentionPolicy: Equatable, Sendable {
    static let entryBounds = 1...10_000
    static let `default` = TranscriptRetentionPolicy(maximumEntries: 500, maximumAge: nil)
    /// Retains nothing older or beyond the newest entry; used to express "history off but recorded".
    static let disabled = TranscriptRetentionPolicy(maximumEntries: 1, maximumAge: 0)

    let maximumEntries: Int
    /// Seconds. `nil` means age is not a retention criterion; `0` prunes everything but the newest.
    let maximumAge: TimeInterval?

    init(maximumEntries: Int, maximumAge: TimeInterval? = nil) {
        self.maximumEntries = min(max(maximumEntries, Self.entryBounds.lowerBound), Self.entryBounds.upperBound)
        self.maximumAge = maximumAge.map { max($0, 0) }
    }

    /// Oldest instant a row may carry and still be retained, or `nil` when age does not prune.
    func earliestRetained(now: Date) -> Date? { maximumAge.map { now.addingTimeInterval(-$0) } }
}

/// Everything the effectful commit path knows about a transcript. Most of it is deliberately
/// unpersistable: the fields below the text exist so the privacy filter can see and then drop them.
struct TranscriptCommitContext: Sendable {
    let sessionID: UUID
    var recordedAt: Date
    var text: String
    var localeIdentifier: String
    var source: TranscriptSource = .live
    var isFinal: Bool = true
    var historyEnabled: Bool = true
    var secureInputActive: Bool = false
    /// Excluded from persistence. Present only so callers need no separate scrubbing step.
    var targetApplicationBundleID: String?
    var targetApplicationPID: pid_t?
    var audioURL: URL?
    var partialTranscript: String?
}

/// Pure decision layer between a commit and the repository. It answers two questions — may this
/// transcript be persisted at all, and what exactly may be written — and performs no effects.
enum TranscriptHistoryPolicy {
    /// Why a commit produced no history row. Exhaustive so refusals stay explainable in tests.
    enum Exclusion: Equatable, Sendable {
        case historyDisabled, secureInput, notFinal, emptyTranscript
    }

    enum Decision: Equatable, Sendable {
        case persist(TranscriptHistoryEntry)
        case exclude(Exclusion)

        var entry: TranscriptHistoryEntry? { if case let .persist(entry) = self { return entry }; return nil }
        var exclusion: Exclusion? { if case let .exclude(reason) = self { return reason }; return nil }
    }

    /// Namespace for session-derived identities; keeps history ids stable across a crash-and-retry.
    static func identity(for sessionID: UUID) -> UUID { sessionID }

    static func decide(_ context: TranscriptCommitContext) -> Decision {
        guard context.historyEnabled else { return .exclude(.historyDisabled) }
        guard !context.secureInputActive else { return .exclude(.secureInput) }
        guard context.isFinal else { return .exclude(.notFinal) }
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .exclude(.emptyTranscript) }
        return .persist(TranscriptHistoryEntry(
            id: identity(for: context.sessionID),
            recordedAt: context.recordedAt,
            text: text,
            localeIdentifier: context.localeIdentifier,
            source: context.source))
    }
}
