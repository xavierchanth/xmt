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
            protocolVersion: KeyboardWireEnvelope.currentVersion + 1,
            session: session,
            sender: .app,
            message: .establishSession
        )
        let data = try JSONEncoder().encode(envelope)
        XCTAssertThrowsError(try KeyboardWireCodec.decode(data)) { error in
            XCTAssertEqual(
                error as? KeyboardWireContractError,
                .unsupportedVersion(KeyboardWireEnvelope.currentVersion + 1)
            )
        }

        let legacy = KeyboardWireEnvelope(
            protocolVersion: KeyboardWireEnvelope.currentVersion - 1,
            session: session,
            sender: .app,
            message: .establishSession
        )
        XCTAssertThrowsError(try KeyboardWireCodec.decode(try JSONEncoder().encode(legacy))) { error in
            XCTAssertEqual(
                error as? KeyboardWireContractError,
                .unsupportedVersion(KeyboardWireEnvelope.currentVersion - 1)
            )
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

    func testInventoryRemovalBalancesHeldOutputAndUnchangedPolicyPreservesIt() throws {
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
            []
        )
        XCTAssertEqual(
            pipeline.receive(.keyUp(attachment: attachment, key: KeyCode(4)), at: .init(milliseconds: 302)).outputs,
            [.modifierUp(.control)]
        )
        XCTAssertThrowsError(try pipeline.replacePolicy(first, at: .init(milliseconds: 303)))
    }

    func testChangedBehaviorPolicyReplacementBalancesHeldOutput() throws {
        let first = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let changed = try ValidatedKeyboardOwnerPolicy.validate(changedPolicyDTO(revision: 2))
        var pipeline = KeyboardTransformationPipeline(policy: first)
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = pipeline.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = pipeline.receive(
            .keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false),
            at: .init(milliseconds: 0)
        )
        XCTAssertEqual(
            pipeline.receive(.deadline, at: .init(milliseconds: 100)).outputs,
            [.modifierDown(.control)]
        )
        XCTAssertEqual(
            try pipeline.replacePolicy(changed, at: .init(milliseconds: 101)).outputs,
            [.modifierUp(.control)]
        )
    }

    func testPolicyIdentityRerouteBalancesFormerAttachmentBeforeReplacement() throws {
        let firstDTO = policyDTO(revision: 1)
        let original = firstDTO.devices[0]
        let replacementDTO = KeyboardPolicyDTO(revision: 2, devices: [.init(
            id: original.id,
            identity: .init(
                builtIn: false, vendorID: 1, productID: 2,
                serialNumber: "serial-b", locationID: 8, transport: "usb"
            ),
            timing: original.timing,
            keys: original.keys
        )])
        var pipeline = KeyboardTransformationPipeline(
            policy: try ValidatedKeyboardOwnerPolicy.validate(firstDTO)
        )
        let firstAttachment = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        let secondAttachment = KeyboardAttachedDevice(
            attachment: .init(),
            descriptor: .init(
                builtIn: false, vendorID: 1, productID: 2,
                serialNumber: "serial-b", locationID: 8, transport: "usb"
            )
        )
        _ = pipeline.replaceInventory([firstAttachment, secondAttachment], at: .init(milliseconds: 0))
        _ = pipeline.receive(
            .keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false),
            at: .init(milliseconds: 0)
        )
        _ = pipeline.receive(.deadline, at: .init(milliseconds: 100))
        XCTAssertEqual(
            try pipeline.replacePolicy(
                ValidatedKeyboardOwnerPolicy.validate(replacementDTO),
                at: .init(milliseconds: 101)
            ).outputs,
            [.modifierUp(.control)]
        )
        XCTAssertFalse(
            pipeline.receive(
                .keyUp(attachment: attachment, key: KeyCode(4)),
                at: .init(milliseconds: 102)
            ).isInScope
        )
        XCTAssertTrue(
            pipeline.receive(
                .keyDown(attachment: secondAttachment.attachment, key: KeyCode(4), isRepeat: false),
                at: .init(milliseconds: 103)
            ).isInScope
        )
    }

    func testRuntimeEmitsThroughInjectedSinkAndRequestsNoIdleDeadlineAfterTap() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = RecordingKeyboardOutputSink()
        let runtime = KeyboardTransformationRuntime(policy: policy, sink: sink, failureHandler: { _ in })
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = try await runtime.receive(.keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false), at: .init(milliseconds: 1))
        let result = try await runtime.receive(.keyUp(attachment: attachment, key: KeyCode(4)), at: .init(milliseconds: 2))
        XCTAssertNil(result.deadline)
        let recorded = await sink.recorded()
        XCTAssertEqual(recorded, [.keyDown(KeyCode(5)), .keyUp(KeyCode(5))])
    }

    func testRuntimeSerializesSinkEffectsAcrossSuspension() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink()
        let runtime = KeyboardTransformationRuntime(
            policy: policy, sink: sink, admissionLimit: 3, failureHandler: { _ in }
        )
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = try await runtime.receive(
            .keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false),
            at: .init(milliseconds: 1)
        )
        await sink.blockNextEmission()

        let first = Task {
            try await runtime.receive(
                .keyUp(attachment: attachment, key: KeyCode(4)),
                at: .init(milliseconds: 2)
            )
        }
        await sink.waitUntilBlocked()
        let second = Task {
            try await runtime.receive(.deadline, at: .init(milliseconds: 3))
        }
        await Task.yield()
        let blockedInvocationCount = await sink.invocationCount()
        XCTAssertEqual(blockedInvocationCount, 3)
        await sink.resumeBlockedEmission()
        _ = try await first.value
        _ = try await second.value
        let finalInvocationCount = await sink.invocationCount()
        XCTAssertEqual(finalInvocationCount, 4)
    }

    func testRuntimeRejectsAdmissionBeyondBound() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink()
        let runtime = KeyboardTransformationRuntime(
            policy: policy, sink: sink, admissionLimit: 1, failureHandler: { _ in }
        )
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = try await runtime.receive(
            .keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false),
            at: .init(milliseconds: 1)
        )
        await sink.blockNextEmission()
        let executing = Task {
            try await runtime.receive(
                .keyUp(attachment: attachment, key: KeyCode(4)),
                at: .init(milliseconds: 2)
            )
        }
        await sink.waitUntilBlocked()
        do {
            _ = try await runtime.receive(.deadline, at: .init(milliseconds: 3))
            XCTFail("expected bounded admission failure")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .admissionFull(limit: 1))
        }
        await sink.resumeBlockedEmission()
        _ = try await executing.value
        do {
            _ = try await runtime.receive(.deadline, at: .init(milliseconds: 4))
            XCTFail("expected admission overflow to fail closed")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .runtimeFailed)
        }
    }

    func testRuntimeFailsClosedAfterSinkFailureAndAllowsTeardown() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink(failures: 1)
        let runtime = KeyboardTransformationRuntime(policy: policy, sink: sink, failureHandler: { _ in })
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        do {
            _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
            XCTFail("expected sink failure")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .sinkFailed)
        }
        do {
            _ = try await runtime.receive(.deadline, at: .init(milliseconds: 1))
            XCTFail("expected failed runtime")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .runtimeFailed)
        }
        try await runtime.teardown(at: .init(milliseconds: 2))
        do {
            _ = try await runtime.receive(.deadline, at: .init(milliseconds: 3))
            XCTFail("expected stopped runtime")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .stopped)
        }
    }

    func testRuntimeTimeoutSignalsFailureAndDefersTeardownUntilSinkQuiesces() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink()
        let failures = KeyboardPipelineFailureRecorder()
        await sink.blockNextEmission()
        let runtime = KeyboardTransformationRuntime(
            policy: policy,
            sink: sink,
            operationDeadline: ImmediateKeyboardOperationDeadline(),
            failureHandler: { error in Task { await failures.record(error) } }
        )
        do {
            _ = try await runtime.replaceInventory([], at: .init(milliseconds: 0))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .operationTimedOut)
        }
        let reportedFailure = await failures.next()
        XCTAssertEqual(reportedFailure, .operationTimedOut)
        do {
            try await runtime.teardown(at: .init(milliseconds: 1))
            XCTFail("expected pending sink cleanup")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .teardownInProgress)
        }
        await sink.resumeBlockedEmission()
    }

    func testQueuedTeardownDoesNotExecuteAfterActiveSinkTimesOut() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink()
        let deadline = LatchedKeyboardOperationDeadline()
        let runtime = KeyboardTransformationRuntime(
            policy: policy,
            sink: sink,
            admissionLimit: 2,
            operationDeadline: deadline,
            failureHandler: { _ in }
        )
        await sink.blockNextEmission()
        let active = Task {
            try await runtime.replaceInventory([], at: .init(milliseconds: 0))
        }
        await sink.waitUntilBlocked()
        let teardown = Task {
            try await runtime.teardown(at: .init(milliseconds: 1))
        }
        while await runtime.queuedOperationCount == 0 { await Task.yield() }
        let invocationsBeforeTimeout = await sink.invocationCount()

        await deadline.fire()
        do {
            _ = try await active.value
            XCTFail("expected active operation timeout")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .operationTimedOut)
        }
        do {
            try await teardown.value
            XCTFail("expected queued teardown to wait for sink quiescence")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .teardownInProgress)
        }
        let invocationsAfterTimeout = await sink.invocationCount()
        XCTAssertEqual(invocationsAfterTimeout, invocationsBeforeTimeout)
        await sink.resumeBlockedEmission()
    }

    func testFailedTeardownRetriesTheSameBalancingOutput() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink()
        let runtime = KeyboardTransformationRuntime(policy: policy, sink: sink, failureHandler: { _ in })
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = try await runtime.receive(
            .keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false),
            at: .init(milliseconds: 0)
        )
        _ = try await runtime.receive(.deadline, at: .init(milliseconds: 100))
        await sink.failNextEmission()
        do {
            try await runtime.teardown(at: .init(milliseconds: 101))
            XCTFail("expected first teardown failure")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .sinkFailed)
        }
        try await runtime.teardown(at: .init(milliseconds: 102))
        let batches = await sink.emittedBatches()
        XCTAssertEqual(Array(batches.suffix(2)), [[.modifierUp(.control)], [.modifierUp(.control)]])
    }

    func testTeardownRetriesAnOrdinaryReleaseThatMayHaveFailedBeforeDelivery() async throws {
        let policy = try ValidatedKeyboardOwnerPolicy.validate(policyDTO(revision: 1))
        let sink = ControllableKeyboardOutputSink()
        let runtime = KeyboardTransformationRuntime(policy: policy, sink: sink, failureHandler: { _ in })
        let attached = KeyboardAttachedDevice(attachment: attachment, descriptor: descriptor())
        _ = try await runtime.replaceInventory([attached], at: .init(milliseconds: 0))
        _ = try await runtime.receive(
            .keyDown(attachment: attachment, key: KeyCode(4), isRepeat: false),
            at: .init(milliseconds: 0)
        )
        _ = try await runtime.receive(.deadline, at: .init(milliseconds: 100))

        await sink.failNextEmission()
        do {
            _ = try await runtime.receive(
                .keyUp(attachment: attachment, key: KeyCode(4)),
                at: .init(milliseconds: 101)
            )
            XCTFail("expected ordinary release failure")
        } catch {
            XCTAssertEqual(error as? KeyboardPipelineError, .sinkFailed)
        }

        try await runtime.teardown(at: .init(milliseconds: 102))
        let batches = await sink.emittedBatches()
        XCTAssertEqual(Array(batches.suffix(2)), [[.modifierUp(.control)], [.modifierUp(.control)]])
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

    private func changedPolicyDTO(revision: UInt64) -> KeyboardPolicyDTO {
        let original = policyDTO(revision: revision).devices[0]
        return .init(revision: revision, devices: [.init(
            id: original.id,
            identity: original.identity,
            timing: original.timing,
            keys: [.init(physicalCode: 4, tapCode: 6, holdModifiers: [.control], timing: nil)],
            productSemantics: original.productSemantics
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

private actor ControllableKeyboardOutputSink: KeyboardVirtualOutputSink {
    enum Failure: Error { case injected }

    private var failuresRemaining: Int
    private var shouldBlockNext = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var invocations = 0
    private var batches: [[KeyboardOutput]] = []

    init(failures: Int = 0) { failuresRemaining = failures }

    func emit(_ outputs: [KeyboardOutput]) async throws {
        invocations += 1
        batches.append(outputs)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure.injected
        }
        if shouldBlockNext {
            shouldBlockNext = false
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { blockedContinuation = $0 }
        }
    }

    func blockNextEmission() { shouldBlockNext = true }
    func failNextEmission() { failuresRemaining += 1 }
    func invocationCount() -> Int { invocations }
    func emittedBatches() -> [[KeyboardOutput]] { batches }

    func waitUntilBlocked() async {
        if blockedContinuation != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func resumeBlockedEmission() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private struct ImmediateKeyboardOperationDeadline: KeyboardTransformationOperationDeadline {
    func wait() async {}
}

private actor LatchedKeyboardOperationDeadline: KeyboardTransformationOperationDeadline {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        fired = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

private actor KeyboardPipelineFailureRecorder {
    private var values: [KeyboardPipelineError] = []
    private var waiters: [CheckedContinuation<KeyboardPipelineError, Never>] = []

    func record(_ error: KeyboardPipelineError) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: error)
        } else {
            values.append(error)
        }
    }

    func next() async -> KeyboardPipelineError {
        if !values.isEmpty { return values.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
