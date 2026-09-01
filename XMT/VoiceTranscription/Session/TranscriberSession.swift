@preconcurrency import AVFoundation
import Foundation
import Speech

/// A `TranscriberSession` is single-use. The caller must finish its input AsyncSequence before
/// calling `finish`; finalization is bounded and cancels analysis if that ordering is violated.
@available(macOS 26.0, *)
actor TranscriberSession {
    enum SessionError: Error { case unsupportedLocale, noCompatibleAudioFormat, sourceFormatChanged, alreadyUsed, finalizationTimedOut }
    struct Update: Sendable, Equatable { let text: String; let isFinal: Bool }
    private enum State { case ready, running, finished }

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var resultTask: Task<String, Error>?
    private var state = State.ready

    init(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw SessionError.unsupportedLocale }
        let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        transcriber = module
        analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
    }

    func bestAvailableAudioFormat() async throws -> AVAudioFormat {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw SessionError.noCompatibleAudioFormat }
        return format
    }

    func start<S: AsyncSequence & Sendable>(buffers: S, update: @escaping @Sendable (Update) -> Void) async throws where S.Element == AVAudioPCMBuffer {
        guard case .ready = state else { throw SessionError.alreadyUsed }
        state = .running
        do {
            let target = try await bestAvailableAudioFormat()
            try await analyzer.prepareToAnalyze(in: target)
            resultTask = consumeResults(update: update)
            // A single converter owns stream state. This producer runs outside the realtime tap,
            // preserves input ordering, and flushes converter delay before ending analyzer input.
            let converted = AsyncThrowingStream<AnalyzerInput, Error> { continuation in
                Task {
                    do {
                        var converter: StreamConverter?
                        for try await buffer in buffers {
                            if converter == nil { converter = try StreamConverter(source: buffer.format, target: target) }
                            for convertedBuffer in try converter!.convert(buffer) {
                                continuation.yield(AnalyzerInput(buffer: convertedBuffer))
                            }
                        }
                        for tail in try converter?.finish() ?? [] where tail.frameLength > 0 {
                            continuation.yield(AnalyzerInput(buffer: tail))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
            try await analyzer.start(inputSequence: converted)
        } catch { await cleanup(); throw error }
    }

    /// Session-owned and consumed serially by the conversion producer; never called by the tap.
    private final class StreamConverter: @unchecked Sendable {
        private let source: AVAudioFormat
        private let target: AVAudioFormat
        private let converter: AVAudioConverter?

        init(source: AVAudioFormat, target: AVAudioFormat) throws {
            self.source = source; self.target = target
            converter = source == target ? nil : AVAudioConverter(from: source, to: target)
            if source != target, converter == nil { throw SessionError.noCompatibleAudioFormat }
        }

        func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
            guard buffer.format == source else { throw SessionError.sourceFormatChanged }
            guard let converter else { return [buffer] }
            return try produceAll(converter: converter, sourceBuffer: buffer, end: false)
        }

        func finish() throws -> [AVAudioPCMBuffer] {
            guard let converter else { return [] }
            return try produceAll(converter: converter, sourceBuffer: nil, end: true)
        }

        private func produceAll(converter: AVAudioConverter, sourceBuffer: AVAudioPCMBuffer?, end: Bool) throws -> [AVAudioPCMBuffer] {
            let frames = sourceBuffer.map { Double($0.frameLength) } ?? 256
            let capacity = AVAudioFrameCount(ceil(frames * target.sampleRate / source.sampleRate)) + 16
            var supplied = false
            var outputs: [AVAudioPCMBuffer] = []
            for _ in 0..<64 {
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                    throw SessionError.noCompatibleAudioFormat
                }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if !supplied, let sourceBuffer {
                        supplied = true; inputStatus.pointee = .haveData; return sourceBuffer
                    }
                    inputStatus.pointee = end ? .endOfStream : .noDataNow; return nil
                }
                if let conversionError { throw conversionError }
                guard status != .error else { throw SessionError.noCompatibleAudioFormat }
                if output.frameLength > 0 { outputs.append(output) }
                switch status {
                case .haveData: continue
                case .inputRanDry, .endOfStream: return outputs
                case .error: throw SessionError.noCompatibleAudioFormat
                @unknown default: throw SessionError.noCompatibleAudioFormat
                }
            }
            throw SessionError.noCompatibleAudioFormat
        }
    }

    /// Input must already have reached end-of-sequence. A non-finishing producer is treated as a
    /// caller contract violation and analysis is cancelled after `timeout`.
    func finish(timeout: Duration = .seconds(5)) async throws -> String {
        guard case .running = state else { throw SessionError.alreadyUsed }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.analyzer.finalizeAndFinishThroughEndOfInput() }
                group.addTask { try await Task.sleep(for: timeout); throw SessionError.finalizationTimedOut }
                _ = try await group.next(); group.cancelAll()
            }
            let text = try await resultTask?.value ?? ""
            resultTask = nil; state = .finished
            return text
        } catch { await cleanup(); throw error }
    }

    func cancel() async { await cleanup() }

    /// Recovery retry always owns a fresh analyzer/results stream; finished sessions are never reused.
    static func retry(fileURL: URL, locale: Locale, update: @escaping @Sendable (Update) -> Void,
                      timeout: Duration = .seconds(30)) async throws -> String {
        let session = try await TranscriberSession(locale: locale)
        return try await session.retryFresh(fileURL: fileURL, update: update, timeout: timeout)
    }

    private func retryFresh(fileURL: URL, update: @escaping @Sendable (Update) -> Void, timeout: Duration) async throws -> String {
        guard case .ready = state else { throw SessionError.alreadyUsed }; state = .running
        do {
            let file = try AVAudioFile(forReading: fileURL)
            try await analyzer.prepareToAnalyze(in: file.processingFormat)
            resultTask = consumeResults(update: update)
            _ = try await analyzer.analyzeSequence(from: file)
            return try await finish(timeout: timeout)
        } catch { await cleanup(); throw error }
    }

    private func cleanup() async {
        await analyzer.cancelAndFinishNow(); resultTask?.cancel(); resultTask = nil; state = .finished
    }

    private func consumeResults(update: @escaping @Sendable (Update) -> Void) -> Task<String, Error> {
        let results = transcriber.results
        return Task {
            var finalized = ""
            for try await result in results {
                let text = String(result.text.characters)
                if result.isFinal { finalized = Self.join(finalized, text); update(.init(text: finalized, isFinal: true)) }
                else { update(.init(text: Self.join(finalized, text), isFinal: false)) }
            }
            return finalized
        }
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }; guard !rhs.isEmpty else { return lhs }
        return lhs.last?.isWhitespace == true || rhs.first?.isWhitespace == true ? lhs + rhs : lhs + " " + rhs
    }
}
