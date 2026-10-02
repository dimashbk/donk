import XCTest
@testable import DonkPerformance

final class RingBufferTests: XCTestCase {
    func testAppendWithinCapacityKeepsOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        [1, 2, 3].forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [1, 2, 3])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.first, 1)
        XCTAssertEqual(buffer.last, 3)
        XCTAssertEqual(buffer[1], 2)
    }

    func testOverflowEvictsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        (1...7).forEach { buffer.append($0) }
        XCTAssertEqual(buffer.elements, [5, 6, 7])
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.first, 5)
        XCTAssertEqual(buffer.last, 7)
        XCTAssertEqual(buffer[0], 5)
        XCTAssertEqual(buffer[2], 7)
    }

    func testRemoveFirstWhilePredicate() {
        var buffer = RingBuffer<Int>(capacity: 5)
        (1...8).forEach { buffer.append($0) }
        buffer.removeFirst { $0 < 6 }
        XCTAssertEqual(buffer.elements, [6, 7, 8])
        buffer.append(9)
        buffer.append(10)
        buffer.append(11)
        XCTAssertEqual(buffer.elements, [7, 8, 9, 10, 11])
    }

    func testRemoveFirstCountAndRemoveAll() {
        var buffer = RingBuffer<Int>(capacity: 4)
        (1...4).forEach { buffer.append($0) }
        buffer.removeFirst(10)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertNil(buffer.first)
        buffer.append(42)
        XCTAssertEqual(buffer.elements, [42])
        buffer.removeAll()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.elements, [])
    }

    func testSuffixAndResize() {
        var buffer = RingBuffer<Int>(capacity: 5)
        (1...9).forEach { buffer.append($0) }
        XCTAssertEqual(buffer.suffix(2), [8, 9])
        XCTAssertEqual(buffer.suffix(50), [5, 6, 7, 8, 9])
        buffer.resize(3)
        XCTAssertEqual(buffer.capacity, 3)
        XCTAssertEqual(buffer.elements, [7, 8, 9])
        buffer.resize(6)
        buffer.append(10)
        XCTAssertEqual(buffer.elements, [7, 8, 9, 10])
    }
}
