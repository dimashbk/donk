import Combine
import Foundation

package final class PublicationQueue<Output>: @unchecked Sendable {
    private let lock = DonkLock()
    private let latestOnly: Bool
    private let deliver: (Output) -> Void
    private var pending: [Output] = []
    private var isDelivering = false

    package init(latestOnly: Bool = false, deliver: @escaping (Output) -> Void) {
        self.latestOnly = latestOnly
        self.deliver = deliver
    }

    package func enqueue(_ value: Output) {
        lock.withLock { pending.append(value) }
    }

    package func flush() {
        let claimed: Bool = lock.withLock {
            guard !isDelivering, !pending.isEmpty else { return false }
            isDelivering = true
            return true
        }
        guard claimed else { return }
        while let batch = nextBatch() {
            if latestOnly {
                if let last = batch.last { deliver(last) }
            } else {
                batch.forEach(deliver)
            }
        }
    }

    private func nextBatch() -> [Output]? {
        lock.withLock {
            guard !pending.isEmpty else {
                isDelivering = false
                return nil
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            return batch
        }
    }
}

package final class LockedBox<Value>: @unchecked Sendable {
    private let lock = DonkLock()
    private var storage: Value

    package init(_ value: Value) {
        storage = value
    }

    package var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

package final class DonkFlag: @unchecked Sendable {
    private let lock = DonkLock()
    private var storage: Bool
    private let subject: CurrentValueSubject<Bool, Never>
    private let publication: PublicationQueue<Bool>

    package init(_ value: Bool) {
        storage = value
        let subject = CurrentValueSubject<Bool, Never>(value)
        self.subject = subject
        publication = PublicationQueue(latestOnly: true) { subject.send($0) }
    }

    package var value: Bool {
        lock.withLock { storage }
    }

    package var publisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    package func set(_ newValue: Bool) {
        let changed: Bool = lock.withLock {
            guard storage != newValue else { return false }
            storage = newValue
            publication.enqueue(newValue)
            return true
        }
        if changed { publication.flush() }
    }
}
