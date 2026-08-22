import Foundation

public enum BoundedAudioQueueError: Error, Equatable {
    case overflow
    case closed
    case multipleConsumers
}

/// A bounded multi-producer, single-consumer channel. Sending never waits.
public final class BoundedAudioQueue<Element>: AsyncSequence, @unchecked Sendable {
    public typealias AsyncIterator = Iterator
    private let capacity: Int
    private let overflowError: @Sendable () -> Error
    private let lock = NSLock()
    private var elements: [Element] = []
    private var waiter: CheckedContinuation<Element?, Error>?
    private var terminal: Result<Void, Error>?
    private var iteratorIssued = false

    public init(capacity: Int, overflowError: @escaping @Sendable () -> Error = { BoundedAudioQueueError.overflow }) {
        precondition(capacity > 0); self.capacity = capacity; self.overflowError = overflowError
    }

    @discardableResult public func send(_ element: Element) -> Result<Void, Error> {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return .failure(BoundedAudioQueueError.closed) }
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: element); return .success(()) }
        guard elements.count < capacity else {
            // Preserve accepted elements, reject this one, and make the overflow terminal.
            // The consumer drains the accepted prefix before observing the error.
            let error = overflowError()
            terminal = .failure(error)
            lock.unlock(); return .failure(error)
        }
        elements.append(element); lock.unlock(); return .success(())
    }

    public func finish(throwing error: Error? = nil) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = error.map(Result.failure) ?? .success(())
        let waiter = self.waiter; self.waiter = nil; lock.unlock()
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }

    public func makeAsyncIterator() -> Iterator {
        lock.lock(); let accepted = !iteratorIssued; iteratorIssued = true; lock.unlock()
        return Iterator(queue: self, accepted: accepted)
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate let queue: BoundedAudioQueue
        fileprivate let accepted: Bool
        public mutating func next() async throws -> Element? {
            guard accepted else { throw BoundedAudioQueueError.multipleConsumers }
            return try await queue.next()
        }
    }

    private func next() async throws -> Element? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !elements.isEmpty { let value = elements.removeFirst(); lock.unlock(); continuation.resume(returning: value) }
            else if let terminal {
                lock.unlock()
                switch terminal { case .success: continuation.resume(returning: nil); case .failure(let error): continuation.resume(throwing: error) }
            } else if waiter != nil { lock.unlock(); continuation.resume(throwing: BoundedAudioQueueError.multipleConsumers) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}
