import Foundation

enum KeyboardWirePeerRole: String, Codable, Equatable, Sendable {
    case app, owner, watchdog
}

struct KeyboardOwnerProcessID: Codable, Equatable, Sendable {
    let value: Int32

    init?(_ value: Int32) {
        guard value > 0 else { return nil }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        let value = try box.decode(Int32.self)
        guard let valid = Self(value) else {
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "owner process ID must be positive")
        }
        self = valid
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(value)
    }
}

struct KeyboardHeartbeatSequence: Codable, Comparable, Sendable {
    let value: UInt64

    init?(_ value: UInt64) {
        guard value > 0 else { return nil }
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        let value = try box.decode(UInt64.self)
        guard let valid = Self(value) else {
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "heartbeat sequence must be positive")
        }
        self = valid
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(value)
    }
}

enum KeyboardLeaseRevocationReason: String, Codable, Equatable, Sendable {
    case configurationDisabled
    case applicationStopping
    case outputLost
    case watchdogLost
    case ownerFault
    case replaced
}

enum KeyboardOwnerFaultCode: String, Codable, Equatable, Sendable {
    case invalidPolicy
    case outputUnavailable
    case ownershipFailed
    case releasePending
    case protocolViolation
    case peerRejected
}

struct KeyboardOwnerFault: Codable, Equatable, Sendable {
    let code: KeyboardOwnerFaultCode
    let diagnostic: String
}

enum KeyboardOwnerState: Equatable, Sendable {
    case inactive
    case acquiring(KeyboardSafetyAttemptID)
    case active(lease: KeyboardSafetyLeaseID, attempt: KeyboardSafetyAttemptID, revision: KeyboardPolicyRevision)
    case releasing(lease: KeyboardSafetyLeaseID?, attempt: KeyboardSafetyAttemptID, reason: KeyboardLeaseRevocationReason)
    case blocked(pendingRelease: KeyboardSafetyAttemptID, fault: KeyboardOwnerFault)
}

extension KeyboardOwnerState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, lease, attempt, revision, reason, fault }
    private enum Kind: String, Codable { case inactive, acquiring, active, releasing, blocked }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(Kind.self, forKey: .kind) {
        case .inactive:
            self = .inactive
        case .acquiring:
            self = .acquiring(try box.decode(KeyboardSafetyAttemptID.self, forKey: .attempt))
        case .active:
            self = .active(
                lease: try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease),
                attempt: try box.decode(KeyboardSafetyAttemptID.self, forKey: .attempt),
                revision: try box.decode(KeyboardPolicyRevision.self, forKey: .revision)
            )
        case .releasing:
            self = .releasing(
                lease: try box.decodeIfPresent(KeyboardSafetyLeaseID.self, forKey: .lease),
                attempt: try box.decode(KeyboardSafetyAttemptID.self, forKey: .attempt),
                reason: try box.decode(KeyboardLeaseRevocationReason.self, forKey: .reason)
            )
        case .blocked:
            self = .blocked(
                pendingRelease: try box.decode(KeyboardSafetyAttemptID.self, forKey: .attempt),
                fault: try box.decode(KeyboardOwnerFault.self, forKey: .fault)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inactive:
            try box.encode(Kind.inactive, forKey: .kind)
        case .acquiring(let attempt):
            try box.encode(Kind.acquiring, forKey: .kind)
            try box.encode(attempt, forKey: .attempt)
        case .active(let lease, let attempt, let revision):
            try box.encode(Kind.active, forKey: .kind)
            try box.encode(lease, forKey: .lease)
            try box.encode(attempt, forKey: .attempt)
            try box.encode(revision, forKey: .revision)
        case .releasing(let lease, let attempt, let reason):
            try box.encode(Kind.releasing, forKey: .kind)
            try box.encodeIfPresent(lease, forKey: .lease)
            try box.encode(attempt, forKey: .attempt)
            try box.encode(reason, forKey: .reason)
        case .blocked(let attempt, let fault):
            try box.encode(Kind.blocked, forKey: .kind)
            try box.encode(attempt, forKey: .attempt)
            try box.encode(fault, forKey: .fault)
        }
    }
}

enum KeyboardWatchdogOutcome: Equatable, Sendable {
    case teardownAcknowledged
    case ownerUnavailable
    case failed(String)
}

extension KeyboardWatchdogOutcome: Codable {
    private enum CodingKeys: String, CodingKey { case kind, diagnostic }
    private enum Kind: String, Codable { case teardownAcknowledged, ownerUnavailable, failed }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(Kind.self, forKey: .kind) {
        case .teardownAcknowledged: self = .teardownAcknowledged
        case .ownerUnavailable: self = .ownerUnavailable
        case .failed: self = .failed(try box.decode(String.self, forKey: .diagnostic))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .teardownAcknowledged:
            try box.encode(Kind.teardownAcknowledged, forKey: .kind)
        case .ownerUnavailable:
            try box.encode(Kind.ownerUnavailable, forKey: .kind)
        case .failed(let diagnostic):
            try box.encode(Kind.failed, forKey: .kind)
            try box.encode(diagnostic, forKey: .diagnostic)
        }
    }
}

enum KeyboardWireMessage: Equatable, Sendable {
    case establishSession
    case offerPolicy(KeyboardPolicyDTO)
    case grantLease(KeyboardSafetyLeaseID)
    case revokeLease(KeyboardSafetyLeaseID, reason: KeyboardLeaseRevocationReason)
    case resetBreaker
    case shutdown
    case sessionAccepted
    case policyAccepted(KeyboardPolicyRevision)
    case policyRejected(KeyboardOwnerFault)
    case ownerState(KeyboardOwnerState)
    case fault(KeyboardOwnerFault)
    case teardownAcknowledged(KeyboardSafetyLeaseID)
    case beginMonitoring(KeyboardSafetyLeaseID, ownerProcessID: KeyboardOwnerProcessID)
    case heartbeat(KeyboardSafetyLeaseID, sequence: KeyboardHeartbeatSequence)
    case watchdogTeardown(KeyboardSafetyLeaseID, reason: KeyboardLeaseRevocationReason)
    case watchdogResult(KeyboardSafetyLeaseID, KeyboardWatchdogOutcome)
}

extension KeyboardWireMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, policy, lease, reason, revision, fault, state, ownerProcessID, sequence, outcome
    }
    private enum Kind: String, Codable {
        case establishSession, offerPolicy, grantLease, revokeLease, resetBreaker, shutdown
        case sessionAccepted, policyAccepted, policyRejected, ownerState, fault, teardownAcknowledged
        case beginMonitoring, heartbeat, watchdogTeardown, watchdogResult
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(Kind.self, forKey: .kind) {
        case .establishSession: self = .establishSession
        case .offerPolicy: self = .offerPolicy(try box.decode(KeyboardPolicyDTO.self, forKey: .policy))
        case .grantLease: self = .grantLease(try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease))
        case .revokeLease:
            self = .revokeLease(
                try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease),
                reason: try box.decode(KeyboardLeaseRevocationReason.self, forKey: .reason)
            )
        case .resetBreaker: self = .resetBreaker
        case .shutdown: self = .shutdown
        case .sessionAccepted: self = .sessionAccepted
        case .policyAccepted: self = .policyAccepted(try box.decode(KeyboardPolicyRevision.self, forKey: .revision))
        case .policyRejected: self = .policyRejected(try box.decode(KeyboardOwnerFault.self, forKey: .fault))
        case .ownerState: self = .ownerState(try box.decode(KeyboardOwnerState.self, forKey: .state))
        case .fault: self = .fault(try box.decode(KeyboardOwnerFault.self, forKey: .fault))
        case .teardownAcknowledged:
            self = .teardownAcknowledged(try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease))
        case .beginMonitoring:
            self = .beginMonitoring(
                try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease),
                ownerProcessID: try box.decode(KeyboardOwnerProcessID.self, forKey: .ownerProcessID)
            )
        case .heartbeat:
            self = .heartbeat(
                try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease),
                sequence: try box.decode(KeyboardHeartbeatSequence.self, forKey: .sequence)
            )
        case .watchdogTeardown:
            self = .watchdogTeardown(
                try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease),
                reason: try box.decode(KeyboardLeaseRevocationReason.self, forKey: .reason)
            )
        case .watchdogResult:
            self = .watchdogResult(
                try box.decode(KeyboardSafetyLeaseID.self, forKey: .lease),
                try box.decode(KeyboardWatchdogOutcome.self, forKey: .outcome)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .establishSession: try box.encode(Kind.establishSession, forKey: .kind)
        case .offerPolicy(let policy):
            try box.encode(Kind.offerPolicy, forKey: .kind); try box.encode(policy, forKey: .policy)
        case .grantLease(let lease):
            try box.encode(Kind.grantLease, forKey: .kind); try box.encode(lease, forKey: .lease)
        case .revokeLease(let lease, let reason):
            try box.encode(Kind.revokeLease, forKey: .kind); try box.encode(lease, forKey: .lease); try box.encode(reason, forKey: .reason)
        case .resetBreaker: try box.encode(Kind.resetBreaker, forKey: .kind)
        case .shutdown: try box.encode(Kind.shutdown, forKey: .kind)
        case .sessionAccepted: try box.encode(Kind.sessionAccepted, forKey: .kind)
        case .policyAccepted(let revision):
            try box.encode(Kind.policyAccepted, forKey: .kind); try box.encode(revision, forKey: .revision)
        case .policyRejected(let fault):
            try box.encode(Kind.policyRejected, forKey: .kind); try box.encode(fault, forKey: .fault)
        case .ownerState(let state):
            try box.encode(Kind.ownerState, forKey: .kind); try box.encode(state, forKey: .state)
        case .fault(let fault):
            try box.encode(Kind.fault, forKey: .kind); try box.encode(fault, forKey: .fault)
        case .teardownAcknowledged(let lease):
            try box.encode(Kind.teardownAcknowledged, forKey: .kind); try box.encode(lease, forKey: .lease)
        case .beginMonitoring(let lease, let ownerProcessID):
            try box.encode(Kind.beginMonitoring, forKey: .kind); try box.encode(lease, forKey: .lease); try box.encode(ownerProcessID, forKey: .ownerProcessID)
        case .heartbeat(let lease, let sequence):
            try box.encode(Kind.heartbeat, forKey: .kind); try box.encode(lease, forKey: .lease); try box.encode(sequence, forKey: .sequence)
        case .watchdogTeardown(let lease, let reason):
            try box.encode(Kind.watchdogTeardown, forKey: .kind); try box.encode(lease, forKey: .lease); try box.encode(reason, forKey: .reason)
        case .watchdogResult(let lease, let outcome):
            try box.encode(Kind.watchdogResult, forKey: .kind); try box.encode(lease, forKey: .lease); try box.encode(outcome, forKey: .outcome)
        }
    }
}

struct KeyboardWireEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let protocolVersion: Int
    let messageID: UUID
    let session: KeyboardSafetySessionID
    let sender: KeyboardWirePeerRole
    let message: KeyboardWireMessage

    init(protocolVersion: Int = Self.currentVersion,
         messageID: UUID = UUID(),
         session: KeyboardSafetySessionID,
         sender: KeyboardWirePeerRole,
         message: KeyboardWireMessage) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.session = session
        self.sender = sender
        self.message = message
    }
}

enum KeyboardWireContractError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedVersion(Int)
    case unexpectedSender(expected: KeyboardWirePeerRole, actual: KeyboardWirePeerRole)
    case unexpectedSession
    case messageNotAllowed(sender: KeyboardWirePeerRole)
    case invalidPolicy(KeyboardPolicyValidationError)
    case malformedPayload
}

enum KeyboardWireCodec {
    static let maximumPayloadBytes = 256 * 1_024

    static func encode(_ envelope: KeyboardWireEnvelope) throws -> Data {
        try validate(envelope)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= maximumPayloadBytes else { throw KeyboardWireContractError.payloadTooLarge }
        return data
    }

    static func decode(_ data: Data,
                       expectedSender: KeyboardWirePeerRole? = nil,
                       expectedSession: KeyboardSafetySessionID? = nil) throws -> KeyboardWireEnvelope {
        guard data.count <= maximumPayloadBytes else { throw KeyboardWireContractError.payloadTooLarge }
        let envelope: KeyboardWireEnvelope
        do { envelope = try JSONDecoder().decode(KeyboardWireEnvelope.self, from: data) }
        catch { throw KeyboardWireContractError.malformedPayload }
        guard envelope.protocolVersion == KeyboardWireEnvelope.currentVersion else {
            throw KeyboardWireContractError.unsupportedVersion(envelope.protocolVersion)
        }
        if let expectedSender, envelope.sender != expectedSender {
            throw KeyboardWireContractError.unexpectedSender(expected: expectedSender, actual: envelope.sender)
        }
        if let expectedSession, envelope.session != expectedSession {
            throw KeyboardWireContractError.unexpectedSession
        }
        try validate(envelope)
        return envelope
    }

    private static func validate(_ envelope: KeyboardWireEnvelope) throws {
        guard envelope.protocolVersion == KeyboardWireEnvelope.currentVersion else {
            throw KeyboardWireContractError.unsupportedVersion(envelope.protocolVersion)
        }
        guard messageIsAllowed(envelope.message, from: envelope.sender) else {
            throw KeyboardWireContractError.messageNotAllowed(sender: envelope.sender)
        }
        guard messageBelongsToSession(envelope.message, session: envelope.session) else {
            throw KeyboardWireContractError.unexpectedSession
        }
        if case .offerPolicy(let policy) = envelope.message {
            do { _ = try ValidatedKeyboardOwnerPolicy.validate(policy) }
            catch let error as KeyboardPolicyValidationError {
                throw KeyboardWireContractError.invalidPolicy(error)
            }
        }
    }

    private static func messageIsAllowed(_ message: KeyboardWireMessage,
                                         from sender: KeyboardWirePeerRole) -> Bool {
        switch (sender, message) {
        case (.app, .establishSession), (.app, .offerPolicy), (.app, .grantLease),
             (.app, .revokeLease), (.app, .resetBreaker), (.app, .shutdown),
             (.app, .beginMonitoring):
            true
        case (.owner, .sessionAccepted), (.owner, .policyAccepted), (.owner, .policyRejected),
             (.owner, .ownerState), (.owner, .fault), (.owner, .teardownAcknowledged),
             (.owner, .heartbeat):
            true
        case (.watchdog, .watchdogTeardown), (.watchdog, .watchdogResult), (.watchdog, .fault):
            true
        default:
            false
        }
    }

    private static func messageBelongsToSession(_ message: KeyboardWireMessage,
                                                session: KeyboardSafetySessionID) -> Bool {
        func owns(_ lease: KeyboardSafetyLeaseID) -> Bool { lease.session == session }
        func owns(_ attempt: KeyboardSafetyAttemptID) -> Bool { attempt.session == session }
        switch message {
        case .grantLease(let lease), .revokeLease(let lease, _), .teardownAcknowledged(let lease),
             .beginMonitoring(let lease, _), .heartbeat(let lease, _),
             .watchdogTeardown(let lease, _), .watchdogResult(let lease, _):
            return owns(lease)
        case .ownerState(let state):
            switch state {
            case .inactive: return true
            case .acquiring(let attempt): return owns(attempt)
            case .active(let lease, let attempt, _): return owns(lease) && owns(attempt)
            case .releasing(let lease, let attempt, _): return (lease.map(owns) ?? true) && owns(attempt)
            case .blocked(let attempt, _): return owns(attempt)
            }
        default:
            return true
        }
    }
}

struct KeyboardPeerIdentity: Equatable, Sendable {
    let processID: Int32
    let signingIdentifier: String
    let teamIdentifier: String
}

protocol KeyboardPeerIdentityVerifying: Sendable {
    func accepts(_ identity: KeyboardPeerIdentity) -> Bool
}

struct KeyboardExpectedPeerVerifier: KeyboardPeerIdentityVerifying {
    let signingIdentifier: String
    let teamIdentifier: String

    func accepts(_ identity: KeyboardPeerIdentity) -> Bool {
        identity.processID > 0 && identity.signingIdentifier == signingIdentifier
            && identity.teamIdentifier == teamIdentifier
    }
}

@objc protocol KeyboardOwnerXPCProtocol {
    func exchange(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
}

@objc protocol KeyboardWatchdogXPCProtocol {
    func exchange(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
}
