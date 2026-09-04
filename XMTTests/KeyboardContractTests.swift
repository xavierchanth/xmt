import XCTest

final class KeyboardContractTests: XCTestCase {
    private let session = KeyboardSafetySessionID(UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
    private let attachment = KeyboardAttachmentID(UUID(uuidString: "30000000-0000-0000-0000-000000000001")!)

    func testValidPolicyCreatesStrictResolverConfiguration() throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        XCTAssertEqual(policy.revision, KeyboardPolicyRevision(1)!)
        XCTAssertEqual(policy.configuration.devices.count, 1)
        XCTAssertEqual(policy.devices.first?.id, KeyboardDeviceID("external-a"))
    }

    func testPolicyRejectsMalformedOrInsufficientIdentity() {
        var dto = policyDTO(revision: 1)
        dto = replacingIdentity(dto, .init(
            builtIn: false, vendorID: 1, productID: 2,
            serialNumber: "  ", locationID: 7, transport: "USB"
        ))
        XCTAssertThrowsError(try ValidatedKeyboardOwnerPolicy.validate(dto)) { error in
            XCTAssertEqual(error as? KeyboardPolicyValidationError, .malformedIdentity(device: "external-a"))
        }

        dto = replacingIdentity(policyDTO(revision: 1), .init(
            builtIn: false, vendorID: 1, productID: 2,
            serialNumber: nil, locationID: nil, transport: "USB"
        ))
        XCTAssertThrowsError(try ValidatedKeyboardOwnerPolicy.validate(dto)) { error in
            XCTAssertEqual(error as? KeyboardPolicyValidationError, .insufficientIdentity(device: "external-a"))
        }
    }

    func testPolicyRejectsDuplicateKeysAndModifiers() {
        let base = policyDTO(revision: 1)
        let device = base.devices[0]
        let duplicateKey = KeyboardPolicyDTO.Device(
            id: device.id, identity: device.identity, timing: device.timing,
            keys: [device.keys[0], device.keys[0]]
        )
        XCTAssertThrowsError(try ValidatedKeyboardOwnerPolicy.validate(.init(revision: 1, devices: [duplicateKey])))

        let key = KeyboardPolicyDTO.Key(
            physicalCode: 4, tapCode: 5, holdModifiers: [.control, .control], timing: nil
        )
        let duplicateModifier = KeyboardPolicyDTO.Device(
            id: device.id, identity: device.identity, timing: device.timing, keys: [key]
        )
        XCTAssertThrowsError(try ValidatedKeyboardOwnerPolicy.validate(.init(revision: 1, devices: [duplicateModifier])))
    }

    func testEveryWireMessageRoundTripsWithItsAllowedSender() throws {
        let lease = KeyboardSafetyLeaseID(session: session, value: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!)
        let attempt = KeyboardSafetyAttemptID(session: session, sequence: 1)!
        let fault = KeyboardOwnerFault(code: .releasePending, diagnostic: "release pending")
        let revision = KeyboardPolicyRevision(1)!
        let cases: [(KeyboardWirePeerRole, KeyboardWireMessage)] = [
            (.app, .establishSession),
            (.app, .offerPolicy(policyDTO(revision: 1))),
            (.app, .grantLease(lease)),
            (.app, .revokeLease(lease, reason: .configurationDisabled)),
            (.app, .resetBreaker),
            (.app, .shutdown),
            (.app, .beginMonitoring(lease, ownerProcessID: KeyboardOwnerProcessID(42)!)),
            (.owner, .sessionAccepted),
            (.owner, .policyAccepted(revision)),
            (.owner, .policyRejected(fault)),
            (.owner, .ownerState(.acquiring(attempt))),
            (.owner, .ownerState(.active(lease: lease, attempt: attempt, revision: revision))),
            (.owner, .ownerState(.releasing(lease: lease, attempt: attempt, reason: .replaced))),
            (.owner, .ownerState(.blocked(pendingRelease: attempt, fault: fault))),
            (.owner, .fault(fault)),
            (.owner, .teardownAcknowledged(lease)),
            (.owner, .heartbeat(lease, sequence: KeyboardHeartbeatSequence(9)!)),
            (.watchdog, .watchdogTeardown(lease, reason: .watchdogLost)),
            (.watchdog, .watchdogResult(lease, .teardownAcknowledged)),
            (.watchdog, .watchdogResult(lease, .ownerUnavailable)),
            (.watchdog, .watchdogResult(lease, .failed("injected")))
        ]

        for (sender, message) in cases {
            let envelope = KeyboardWireEnvelope(session: session, sender: sender, message: message)
            let data = try KeyboardWireCodec.encode(envelope)
            XCTAssertEqual(try KeyboardWireCodec.decode(data, expectedSender: sender, expectedSession: session), envelope)
        }
    }

    func testWireRejectsUnsupportedVersionSenderAndSession() throws {
        let envelope = KeyboardWireEnvelope(
            protocolVersion: 99, session: session, sender: .app, message: .establishSession
        )
        let data = try JSONEncoder().encode(envelope)
        XCTAssertThrowsError(try KeyboardWireCodec.decode(data)) { error in
            XCTAssertEqual(error as? KeyboardWireContractError, .unsupportedVersion(99))
        }

        let valid = try KeyboardWireCodec.encode(.init(session: session, sender: .app, message: .establishSession))
        XCTAssertThrowsError(try KeyboardWireCodec.decode(valid, expectedSender: .owner))
        XCTAssertThrowsError(try KeyboardWireCodec.decode(valid, expectedSession: KeyboardSafetySessionID()))
    }

    func testWireRejectsWrongRoleAndCrossSessionLease() {
        let wrongRole = KeyboardWireEnvelope(session: session, sender: .watchdog, message: .grantLease(.init(session: session)))
        XCTAssertThrowsError(try KeyboardWireCodec.encode(wrongRole))

        let otherLease = KeyboardSafetyLeaseID(session: KeyboardSafetySessionID())
        let wrongSession = KeyboardWireEnvelope(session: session, sender: .app, message: .grantLease(otherLease))
        XCTAssertThrowsError(try KeyboardWireCodec.encode(wrongSession))
    }

    func testWireRejectsOversizedAndMalformedPayloads() {
        XCTAssertThrowsError(try KeyboardWireCodec.decode(Data(repeating: 0, count: KeyboardWireCodec.maximumPayloadBytes + 1)))
        XCTAssertThrowsError(try KeyboardWireCodec.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardPolicyRevision.self, from: Data("0".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardOwnerProcessID.self, from: Data("0".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyboardHeartbeatSequence.self, from: Data("0".utf8)))
    }

    func testPeerVerifierRequiresExactSigningIdentityAndPositivePID() {
        let verifier = KeyboardExpectedPeerVerifier(signingIdentifier: "com.xavierchanth.xmt.owner", teamIdentifier: "TEAM")
        XCTAssertTrue(verifier.accepts(.init(processID: 42, signingIdentifier: "com.xavierchanth.xmt.owner", teamIdentifier: "TEAM")))
        XCTAssertFalse(verifier.accepts(.init(processID: 0, signingIdentifier: "com.xavierchanth.xmt.owner", teamIdentifier: "TEAM")))
        XCTAssertFalse(verifier.accepts(.init(processID: 42, signingIdentifier: "other", teamIdentifier: "TEAM")))
    }

    func testPipelineResolvesOnlyExplicitUniqueInventoryAndEmitsTap() throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        var pipeline = KeyboardTransformationPipeline(policy: policy)
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = pipeline.replaceInventory([attached], at: .init(milliseconds: 0))

        let down = pipeline.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 10))
        XCTAssertEqual(down.outputs, [])
        XCTAssertEqual(down.deadline, .init(milliseconds: 110))
        let up = pipeline.receive(.keyUp(attachment: attachment, key: KeyCode(4)), at: .init(milliseconds: 20))
        XCTAssertEqual(up.outputs, [.keyDown(KeyCode(5)), .keyUp(KeyCode(5))])

        var excluded = KeyboardTransformationPipeline(policy: policy)
        _ = excluded.replaceInventory([], at: .init(milliseconds: 0))
        XCTAssertFalse(excluded.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 1)).isInScope)

        var ambiguous = KeyboardTransformationPipeline(policy: policy)
        _ = ambiguous.replaceInventory([attached, .init(attachment: .init(), descriptor: descriptor())], at: .init(milliseconds: 0))
        XCTAssertFalse(ambiguous.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 1)).isInScope)
    }

    func testOneIdentityRuleCannotOwnTwoDistinctAttachments() throws {
        let base = policyDTO(revision: 1)
        let device = base.devices[0]
        let serialOnlyIdentity = KeyboardPolicyDTO.Identity(
            builtIn: false, vendorID: 1, productID: 2,
            serialNumber: "serial-a", locationID: nil, transport: "usb"
        )
        let policy = try ValidatedKeyboardOwnerPolicy.validate(.init(revision: 1, devices: [.init(
            id: device.id, identity: serialOnlyIdentity, timing: device.timing, keys: device.keys
        )]))
        let first = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        let second = KeyboardAttachedDevice(
            attachment: .init(),
            descriptor: .init(
                builtIn: false, vendorID: 1, productID: 2,
                serialNumber: "serial-a", locationID: 8, transport: "usb"
            )
        )
        var pipeline = KeyboardTransformationPipeline(policy: policy)
        _ = pipeline.replaceInventory([first, second], at: .init(milliseconds: 0))
        XCTAssertFalse(pipeline.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 1)).isInScope)
    }

    func testInventoryRemovalAndPolicyReplacementBalanceHeldOutput() throws {
        let first = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let second = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 2))
        var pipeline = KeyboardTransformationPipeline(policy: first)
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = pipeline.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = pipeline.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 0))
        XCTAssertEqual(
            pipeline.receive(.deadline, at: .init(milliseconds: 100)).outputs,
            [.modifierDown(.control)]
        )
        XCTAssertEqual(
            pipeline.replaceInventory([], at: .init(milliseconds: 101)).outputs,
            [.modifierUp(.control)]
        )

        _ = pipeline.replaceInventory([attached], at: .init(milliseconds: 200))
        _ = pipeline.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 200))
        _ = pipeline.receive(.deadline, at: .init(milliseconds: 300))
        XCTAssertEqual(
            try pipeline.replacePolicy(second, at: .init(milliseconds: 301)).outputs,
            [.modifierUp(.control)]
        )
        XCTAssertThrowsError(try pipeline.replacePolicy(first, at: .init(milliseconds: 302)))
    }

    func testRuntimeEmitsThroughInjectedSinkAndRequestsNoIdleDeadlineAfterTap() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = RecordingKeyboardOutputSink()
        let runtime = KeyboardTransformationRuntime(policy: policy, sink: sink)
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = try await runtime.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 1))
        let result = try await runtime.receive(.keyUp(attachment: attachment, key: KeyCode(4)), at: .init(milliseconds: 2))
        XCTAssertNil(result.deadline)
        let recorded = await sink.recorded()
        XCTAssertEqual(recorded, [.keyDown(KeyCode(5)), .keyUp(KeyCode(5))])
    }

    private func policyDTO(revision: UInt64) -> KeyboardPolicyDTO {
        .init(revision: revision, devices: [.init(
            id: "external-a",
            identity: .init(
                builtIn: false, vendorID: 1, productID: 2,
                serialNumber: "serial-a", locationID: 7, transport: "USB"
            ),
            timing: .init(holdMilliseconds: 100, quickTapMilliseconds: 0, rollover: .timeoutOnly),
            keys: [.init(physicalCode: 4, tapCode: 5, holdModifiers: [.control], timing: nil)]
        )])
    }

    private func descriptor() -> KeyboardDeviceDescriptor {
        .init(builtIn: false, vendorID: 1, productID: 2, serialNumber: "serial-a", locationID: 7, transport: "usb")
    }

    private func replacingIdentity(_ dto: KeyboardPolicyDTO,
                                   _ identity: KeyboardPolicyDTO.Identity) -> KeyboardPolicyDTO {
        let device = dto.devices[0]
        return .init(revision: dto.revision, devices: [.init(
            id: device.id, identity: identity, timing: device.timing, keys: device.keys
        )])
    }
}

private actor RecordingKeyboardOutputSink: KeyboardVirtualOutputSink {
    private var values: [KeyboardOutput] = []
    func emit(_ outputs: [KeyboardOutput]) async throws { values += outputs }
    func recorded() -> [KeyboardOutput] { values }
}
