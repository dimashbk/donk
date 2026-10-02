import Foundation
import os

package final class DonkLock: @unchecked Sendable {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    package init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always)
    package func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(pointer)
        defer { os_unfair_lock_unlock(pointer) }
        return try body()
    }
}

package final class WeakIdentitySet<Element: AnyObject>: @unchecked Sendable {
    private let lock = DonkLock()
    private let table = NSHashTable<Element>(options: [.weakMemory, .objectPointerPersonality])

    package init() {}

    package func insert(_ element: Element) {
        lock.withLock { table.add(element) }
    }

    package func remove(_ element: Element) {
        lock.withLock { table.remove(element) }
    }

    package func contains(_ element: Element) -> Bool {
        lock.withLock { table.contains(element) }
    }
}
