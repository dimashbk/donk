import Darwin
import XCTest
@testable import DonkPerformance

final class SamplerTests: XCTestCase {
    func testCPUSampleIsSane() {
        let snapshot = CPUSampler.sample()
        XCTAssertGreaterThanOrEqual(snapshot.total, 0)
        XCTAssertLessThan(snapshot.total, Double(CPUSampler.processorCount) * 100 + 1)
        XCTAssertGreaterThan(snapshot.threadCount, 0)
        XCTAssertFalse(snapshot.threads.isEmpty)
        XCTAssertTrue(snapshot.threads.contains { $0.isMain }, "main thread should be labelled")
        XCTAssertTrue(snapshot.threads.allSatisfy { $0.cpu >= 0 })
        XCTAssertEqual(snapshot.threads.map(\.cpu), snapshot.threads.map(\.cpu).sorted(by: >))
    }

    func testCPUSampleSeesBusyNamedThread() {
        let stop = ManagedAtomicFlag()
        let started = expectation(description: "spinner started")
        let thread = Thread {
            started.fulfill()
            var value: UInt64 = 0
            while !stop.isSet {
                value = value &* 6364136223846793005 &+ 1
            }
            blackHole(value)
        }
        thread.name = "donk.test.spinner"
        thread.start()
        wait(for: [started], timeout: 2)
        Thread.sleep(forTimeInterval: 0.6)
        let snapshot = CPUSampler.sample()
        stop.set()
        let spinner = snapshot.threads.first { $0.name == "donk.test.spinner" }
        XCTAssertNotNil(spinner, "named thread should be listed: \(snapshot.threads.map(\.name))")
        XCTAssertGreaterThan(spinner?.cpu ?? 0, 30)
        XCTAssertGreaterThan(snapshot.total, 30)
    }

    func testMemoryFootprintIsPositiveAndTracksAllocations() {
        let before = MemorySampler.footprint()
        XCTAssertGreaterThan(before, 1_048_576)
        let size = 64 * 1_048_576
        guard let buffer = malloc(size) else {
            XCTFail("allocation failed")
            return
        }
        memset(buffer, 0xAB, size)
        let after = MemorySampler.footprint()
        free(buffer)
        XCTAssertGreaterThan(Int64(after) - Int64(before), 40 * 1_048_576)
        let reading = MemorySampler.sample()
        XCTAssertGreaterThan(reading.footprint, 0)
        if let limit = reading.limit {
            XCTAssertGreaterThan(limit, reading.footprint)
            XCTAssertEqual(limit, reading.footprint + reading.available)
        } else {
            XCTAssertEqual(reading.available, 0)
        }
    }

    func testGPUSamplerNeverReportsNegativeValues() {
        let sampler = GPUSampler()
        var values: [Double] = []
        for index in 0..<8 {
            if let value = sampler.sample(now: 100 + Double(index)) {
                values.append(value)
            }
        }
        XCTAssertTrue(values.allSatisfy { $0 >= 0 })
        if GPUSampler.cumulativeNanoseconds() == 0 {
            XCTAssertEqual(sampler.availability, .unavailable)
            XCTAssertTrue(values.isEmpty)
        }
    }

    func testThreadPortsDoNotLeakAcrossThousandSamples() {
        let port = pthread_mach_thread_np(pthread_self())
        let refsBefore = sendRefs(port)
        let namesBefore = portNameCount()
        for _ in 0..<1000 {
            _ = CPUSampler.sample()
        }
        let refsAfter = sendRefs(port)
        let namesAfter = portNameCount()
        XCTAssertEqual(refsBefore, refsAfter, "send rights on the current thread port changed")
        XCTAssertGreaterThan(namesBefore, 0)
        XCTAssertLessThanOrEqual(namesAfter, namesBefore + 8, "port names grew from \(namesBefore) to \(namesAfter)")
    }

    // MARK: - Helpers

    private func sendRefs(_ port: mach_port_t) -> mach_port_urefs_t {
        var refs: mach_port_urefs_t = 0
        let result = mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &refs)
        XCTAssertEqual(result, KERN_SUCCESS)
        return refs
    }

    private func portNameCount() -> Int {
        var names: mach_port_name_array_t?
        var namesCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typesCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS else { return -1 }
        if let names {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)), vm_size_t(Int(namesCount) * MemoryLayout<mach_port_name_t>.stride))
        }
        if let types {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)), vm_size_t(Int(typesCount) * MemoryLayout<mach_port_type_t>.stride))
        }
        return Int(namesCount)
    }
}

final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@inline(never)
func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}
