import Combine
import XCTest
@testable import DonkCore

final class NetworkStoreTests: XCTestCase {
    func testAddSnapshotNewestFirstAndLookup() {
        let store = NetworkStore()
        let entries = (0..<3).map { httpEntry(url: "https://example.com/\($0)") }
        entries.forEach(store.add)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.snapshot().map(\.id), entries.reversed().map(\.id))
        XCTAssertEqual(store.entry(entries[1].id)?.request.url, "https://example.com/1")
        XCTAssertNil(store.entry(UUID()))
    }

    func testUpdateMutatesEntryAndEmitsEvent() {
        let store = NetworkStore()
        let events = EventRecorder(store.events)
        let entry = httpEntry(state: .pending, status: nil)
        store.add(entry)
        store.update(entry.id) { value in
            value.state = .completed
            value.response = ResponseSnapshot(statusCode: 201)
            value.id = UUID()
        }
        store.update(UUID()) { $0.state = .failed }
        XCTAssertEqual(store.entry(entry.id)?.state, .completed)
        XCTAssertEqual(store.entry(entry.id)?.response?.statusCode, 201)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(events.values, [.added(entry.id), .updated(entry.id)])
    }

    func testReAddingSameIDReplacesEntry() {
        let store = NetworkStore()
        let events = EventRecorder(store.events)
        let id = UUID()
        store.add(httpEntry(id: id, url: "https://a.com/1"))
        store.add(httpEntry(id: id, url: "https://a.com/2"))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entry(id)?.request.url, "https://a.com/2")
        XCTAssertEqual(events.values, [.added(id), .updated(id)])
    }

    func testRingBufferEvictsOldestButKeepsPinned() {
        let store = NetworkStore(limit: 3)
        let events = EventRecorder(store.events)
        let pinned = httpEntry(isPinned: true)
        let others = (0..<4).map { _ in httpEntry() }
        store.add(pinned)
        others.forEach(store.add)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.snapshot().map(\.id), [others[3].id, others[2].id, pinned.id])
        let removed = events.values.compactMap { event -> Set<UUID>? in
            if case let .removed(ids) = event { return ids }
            return nil
        }
        XCTAssertEqual(removed, [[others[0].id], [others[1].id]])
    }

    func testNewestEntrySurvivesWhenPinnedFillTheLimit() {
        let store = NetworkStore(limit: 2)
        let pinned = (0..<2).map { _ in httpEntry(isPinned: true) }
        pinned.forEach(store.add)
        let first = httpEntry()
        let second = httpEntry()
        store.add(first)
        XCTAssertNotNil(store.entry(first.id))
        store.add(second)
        XCTAssertNil(store.entry(first.id))
        XCTAssertNotNil(store.entry(second.id))
        XCTAssertEqual(Set(store.snapshot().map(\.id)), Set(pinned.map(\.id) + [second.id]))
    }

    func testPinningThroughUpdateProtectsFromEviction() {
        let store = NetworkStore(limit: 2)
        let oldest = httpEntry()
        store.add(oldest)
        store.update(oldest.id) { $0.isPinned = true }
        (0..<5).forEach { _ in store.add(httpEntry()) }
        XCTAssertNotNil(store.entry(oldest.id))
        XCTAssertEqual(store.count, 2)
    }

    func testLoweringLimitEvictsImmediately() {
        let store = NetworkStore(limit: 10)
        let entries = (0..<6).map { _ in httpEntry() }
        entries.forEach(store.add)
        let events = EventRecorder(store.events)
        store.limit = 2
        XCTAssertEqual(store.limit, 2)
        XCTAssertEqual(store.snapshot().map(\.id), [entries[5].id, entries[4].id])
        XCTAssertEqual(events.values, [.removed(Set(entries[0..<4].map(\.id)))])
    }

    func testManyAddsKeepOrderAcrossCompaction() {
        let store = NetworkStore(limit: 50)
        var all: [NetworkEntry] = []
        for index in 0..<5_000 {
            let entry = httpEntry(url: "https://h.com/\(index)", isPinned: index == 3)
            all.append(entry)
            store.add(entry)
            if index % 97 == 0 {
                store.remove([all[max(0, index - 10)].id])
            }
        }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 50)
        XCTAssertEqual(snapshot.first?.id, all.last?.id)
        XCTAssertEqual(snapshot.last?.id, all[3].id)
        let unpinned = snapshot.filter { !$0.isPinned }.map(\.id)
        XCTAssertEqual(unpinned, all.suffix(49).reversed().map(\.id))
    }

    func testRemoveThenEvictKeepsCountsConsistent() {
        let store = NetworkStore(limit: 5)
        let first = (0..<5).map { _ in httpEntry() }
        first.forEach(store.add)
        store.remove([first[1].id, first[3].id, UUID()])
        XCTAssertEqual(store.count, 3)
        let second = (0..<4).map { _ in httpEntry() }
        second.forEach(store.add)
        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.snapshot().map(\.id), [second[3].id, second[2].id, second[1].id, second[0].id, first[4].id])
    }

    func testRemoveEmitsOnlyExistingIDs() {
        let store = NetworkStore()
        let entry = httpEntry()
        store.add(entry)
        let events = EventRecorder(store.events)
        store.remove([UUID()])
        store.remove([entry.id, UUID()])
        XCTAssertEqual(events.values, [.removed([entry.id])])
        XCTAssertEqual(store.count, 0)
    }

    func testClearKeepsPinnedByDefault() {
        let store = NetworkStore()
        let pinned = httpEntry(isPinned: true)
        store.add(httpEntry())
        store.add(pinned)
        store.add(httpEntry())
        let events = EventRecorder(store.events)
        store.clear()
        XCTAssertEqual(store.snapshot().map(\.id), [pinned.id])
        store.add(httpEntry())
        XCTAssertEqual(store.count, 2)
        store.clear(keepPinned: false)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.snapshot().isEmpty)
        XCTAssertEqual(events.values.filter { $0 == .cleared }.count, 2)
    }

    func testHostsAreSortedUniqueAndLowercased() {
        let store = NetworkStore()
        store.add(httpEntry(url: "https://b.example.com/x"))
        store.add(httpEntry(url: "https://A.example.com/y"))
        store.add(httpEntry(url: "https://a.example.com/z"))
        store.add(httpEntry(url: "about:blank"))
        XCTAssertEqual(store.hosts, ["a.example.com", "b.example.com"])
    }

    func testSettingsFlags() {
        let store = NetworkStore(limit: 0, maxBodySize: -5)
        XCTAssertEqual(store.limit, 1)
        XCTAssertEqual(store.maxBodySize, 0)
        XCTAssertTrue(store.isCaptureEnabled)
        store.isCaptureEnabled = false
        XCTAssertFalse(store.isCaptureEnabled)
        store.configure(with: NetworkSettings(maxBodySize: 1024, limit: 10))
        XCTAssertEqual(store.limit, 10)
        XCTAssertEqual(store.maxBodySize, 1024)
    }

    func testConcurrentAddsUpdatesAndReads() {
        let store = NetworkStore(limit: 10_000)
        let events = EventRecorder(store.events)
        let ids = (0..<200).map { _ in UUID() }
        let updatesPerEntry = 50
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            let id = ids[index]
            store.add(httpEntry(id: id, state: .pending, status: 0))
            for _ in 0..<updatesPerEntry {
                store.update(id) { $0.response?.statusCode += 1 }
                if index % 10 == 0 {
                    _ = store.snapshot()
                    _ = store.hosts
                }
            }
            store.update(id) { $0.state = .completed }
        }
        XCTAssertEqual(store.count, ids.count)
        for id in ids {
            XCTAssertEqual(store.entry(id)?.response?.statusCode, updatesPerEntry)
            XCTAssertEqual(store.entry(id)?.state, .completed)
        }
        XCTAssertEqual(events.values.count, ids.count * (updatesPerEntry + 2))
    }

    func testConcurrentAddsWithEvictionStayWithinLimit() {
        let store = NetworkStore(limit: 100)
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            store.add(httpEntry(isPinned: index % 500 == 0))
            if index % 7 == 0 {
                _ = store.snapshot()
            }
        }
        XCTAssertEqual(store.count, 100)
        XCTAssertEqual(store.snapshot().count, 100)
        XCTAssertEqual(store.snapshot().filter(\.isPinned).count, 4)
    }

    func testRemoveThenAddSameIDKeepsASingleSlot() {
        let store = NetworkStore(limit: 3)
        let id = UUID()
        store.add(httpEntry(id: id, url: "https://a.com/1"))
        store.remove([id])
        store.add(httpEntry(id: id, url: "https://a.com/2"))
        XCTAssertEqual(store.snapshot().map(\.id), [id])
        XCTAssertEqual(store.entry(id)?.request.url, "https://a.com/2")
        let others = (0..<5).map { _ in httpEntry() }
        others.forEach(store.add)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.snapshot().map(\.id), others.suffix(3).reversed().map(\.id))
        for _ in 0..<200 {
            store.remove([others[4].id])
            store.add(others[4])
        }
        XCTAssertEqual(store.snapshot().map(\.id), [others[4].id, others[3].id, others[2].id])
    }

    func testTotalBytesBudgetEvictsOldestUnpinned() {
        let store = NetworkStore(limit: 100, maxTotalBytes: 1_000)
        let events = EventRecorder(store.events)
        let body = BodyData(data: Data(repeating: 0x61, count: 300), contentType: "text/plain", limit: .max)
        let pinned = httpEntry(body: body, isPinned: true)
        store.add(pinned)
        let entries = (0..<4).map { _ in httpEntry(body: body, responseBody: nil) }
        entries.forEach(store.add)
        XCTAssertEqual(store.snapshot().map(\.id), [entries[3].id, entries[2].id, pinned.id])
        XCTAssertEqual(store.totalBytes, 900)
        let removed = events.values.compactMap { event -> Set<UUID>? in
            if case let .removed(ids) = event { return ids }
            return nil
        }
        XCTAssertEqual(removed, [[entries[0].id], [entries[1].id]])
        store.maxTotalBytes = 600
        XCTAssertEqual(store.snapshot().map(\.id), [entries[3].id, pinned.id])
        store.clear()
        XCTAssertEqual(store.totalBytes, 300)
    }

    func testGrowingEntryEvictsOthersButNeverItself() {
        let store = NetworkStore(limit: 100, maxTotalBytes: 1_000)
        let small = (0..<3).map { _ in httpEntry(body: BodyData(text: String(repeating: "x", count: 200))) }
        small.forEach(store.add)
        let stream = grpcEntry(callType: .serverStreaming, state: .streaming, statusCode: nil)
        store.add(stream)
        for index in 0..<10 {
            store.update(stream.id) { entry in
                entry.grpc?.append(GRPCMessage(direction: .received, typeName: "T", size: 100, json: String(repeating: "\(index)", count: 100)))
            }
        }
        XCTAssertEqual(store.snapshot().map(\.id), [stream.id])
        XCTAssertEqual(store.totalBytes, 1_000)
        XCTAssertEqual(store.entry(stream.id)?.grpc?.messageCount, 10)
    }

    func testConcurrentMutationsPublishEventsInOrder() {
        let store = NetworkStore(limit: 50)
        let lock = NSLock()
        var seen = Set<UUID>()
        var outOfOrder = 0
        var inside = 0
        var maxInside = 0
        let cancellable = store.events.sink { event in
            lock.lock()
            inside += 1
            maxInside = max(maxInside, inside)
            switch event {
            case let .added(id):
                seen.insert(id)
            case let .updated(id):
                if !seen.contains(id) { outOfOrder += 1 }
            case .removed, .cleared:
                break
            }
            inside -= 1
            lock.unlock()
        }
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            let entry = httpEntry(state: .pending, status: nil)
            store.add(entry)
            store.update(entry.id) { $0.state = .completed }
            store.update(entry.id) { $0.isPinned = false }
        }
        cancellable.cancel()
        XCTAssertEqual(outOfOrder, 0)
        XCTAssertEqual(maxInside, 1)
        XCTAssertEqual(store.count, 50)
    }

    func testEventsAreDeliveredOutsideTheLock() {
        let store = NetworkStore()
        let entry = httpEntry()
        var observed: [Int] = []
        let cancellable = store.events.sink { _ in
            observed.append(store.count)
            _ = store.snapshot()
        }
        store.add(entry)
        store.update(entry.id) { $0.isPinned = true }
        cancellable.cancel()
        XCTAssertEqual(observed, [1, 1])
    }
}
