import Foundation

struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    var capacity: Int {
        storage.count
    }

    var isEmpty: Bool {
        count == 0
    }

    var first: Element? {
        count == 0 ? nil : storage[physicalIndex(0)]
    }

    var last: Element? {
        count == 0 ? nil : storage[physicalIndex(count - 1)]
    }

    mutating func append(_ element: Element) {
        if count < storage.count {
            storage[physicalIndex(count)] = element
            count += 1
        } else {
            storage[head] = element
            head = (head + 1) % storage.count
        }
    }

    mutating func removeFirst(_ amount: Int = 1) {
        let removed = min(max(0, amount), count)
        for offset in 0..<removed {
            storage[physicalIndex(offset)] = nil
        }
        head = (head + removed) % storage.count
        count -= removed
    }

    mutating func removeFirst(while predicate: (Element) -> Bool) {
        var removed = 0
        while removed < count, let element = storage[physicalIndex(removed)], predicate(element) {
            removed += 1
        }
        removeFirst(removed)
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }

    mutating func resize(_ newCapacity: Int) {
        let capacity = max(1, newCapacity)
        guard capacity != storage.count else { return }
        let kept = Array(elements.suffix(capacity))
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
        kept.forEach { append($0) }
    }

    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "RingBuffer index out of range")
        guard let element = storage[physicalIndex(index)] else {
            preconditionFailure("RingBuffer slot is empty")
        }
        return element
    }

    var elements: [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            if let element = storage[physicalIndex(offset)] {
                result.append(element)
            }
        }
        return result
    }

    func suffix(_ maxLength: Int) -> [Element] {
        let length = min(max(0, maxLength), count)
        var result: [Element] = []
        result.reserveCapacity(length)
        for offset in (count - length)..<count {
            if let element = storage[physicalIndex(offset)] {
                result.append(element)
            }
        }
        return result
    }

    private func physicalIndex(_ logical: Int) -> Int {
        (head + logical) % storage.count
    }
}
