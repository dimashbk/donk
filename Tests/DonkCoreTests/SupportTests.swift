import Foundation
import XCTest
@testable import DonkCore

final class DonkEnvironmentTests: XCTestCase {
    func testInternalConfigurationsAreTrackedByIdentity() {
        let marked = URLSessionConfiguration.ephemeral
        let other = URLSessionConfiguration.ephemeral
        DonkEnvironment.markInternal(marked)
        XCTAssertTrue(DonkEnvironment.isInternal(marked))
        XCTAssertFalse(DonkEnvironment.isInternal(other))
        XCTAssertFalse(DonkEnvironment.isInternal(marked.copy() as! URLSessionConfiguration))
    }

    func testInternalSessionAndKey() {
        XCTAssertFalse(DonkEnvironment.internalRequestKey.isEmpty)
        let session = DonkEnvironment.internalSession
        XCTAssertTrue(session === DonkEnvironment.internalSession)
        XCTAssertNil(session.configuration.identifier)
    }

    func testAppInfo() {
        let info = DonkEnvironment.appInfo
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertTrue(info.osVersion.hasPrefix("\(version.majorVersion).\(version.minorVersion)"))
        XCTAssertFalse(info.deviceModel.isEmpty)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            XCTAssertEqual(info.deviceModel, simulated)
        }
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertEqual(info.bundleID, Bundle.main.bundleIdentifier ?? "")
    }

    func testVersion() {
        XCTAssertEqual(DonkEnvironment.version, "0.2.0")
        XCTAssertEqual(HARExporter.creatorVersion, DonkEnvironment.version)
    }

    func testActiveFlagPublishesChanges() {
        XCTAssertFalse(DonkEnvironment.isActive)
        let events = EventRecorder(DonkEnvironment.activation)
        DonkEnvironment.setActive(true)
        XCTAssertTrue(DonkEnvironment.isActive)
        DonkEnvironment.setActive(true)
        DonkEnvironment.setActive(false)
        XCTAssertFalse(DonkEnvironment.isActive)
        XCTAssertEqual(events.values, [false, true, false])
        XCTAssertNotNil(NSClassFromString("DonkCoreImageSentinel"))
    }

    func testDebuggerVisibilityFlag() {
        XCTAssertFalse(DonkEnvironment.isDebuggerVisible)
        let events = EventRecorder(DonkEnvironment.debuggerVisibility)
        DonkEnvironment.setDebuggerVisible(true)
        XCTAssertTrue(DonkEnvironment.isDebuggerVisible)
        DonkEnvironment.setDebuggerVisible(false)
        XCTAssertEqual(events.values, [false, true, false])
    }

    @MainActor
    func testRequestHideDebuggerCallsHandler() {
        var calls = 0
        DonkEnvironment.requestHideDebugger()
        DonkEnvironment.hideDebuggerHandler = { calls += 1 }
        DonkEnvironment.requestHideDebugger()
        DonkEnvironment.requestHideDebugger()
        DonkEnvironment.hideDebuggerHandler = nil
        DonkEnvironment.requestHideDebugger()
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentFlagChangesPublishTheFinalValueLast() {
        let events = EventRecorder(DonkEnvironment.debuggerVisibility)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            DonkEnvironment.setDebuggerVisible(index % 2 == 0)
        }
        DonkEnvironment.setDebuggerVisible(false)
        XCTAssertEqual(events.values.last, false)
        XCTAssertFalse(DonkEnvironment.isDebuggerVisible)
    }
}

final class PublicationQueueTests: XCTestCase {
    func testDeliversInEnqueueOrderWithoutConcurrentDelivery() {
        let lock = NSLock()
        var delivered: [Int] = []
        var inside = 0
        var maxInside = 0
        var queue: PublicationQueue<Int>!
        queue = PublicationQueue { value in
            lock.lock()
            inside += 1
            maxInside = max(maxInside, inside)
            delivered.append(value)
            lock.unlock()
            usleep(10)
            lock.lock()
            inside -= 1
            lock.unlock()
        }
        let stateLock = NSLock()
        var counter = 0
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            stateLock.lock()
            counter += 1
            queue.enqueue(counter)
            stateLock.unlock()
            queue.flush()
        }
        XCTAssertEqual(delivered, Array(1...2_000))
        XCTAssertEqual(maxInside, 1)
    }

    func testReentrantEnqueueIsDeliveredAfterTheCurrentValue() {
        var delivered: [Int] = []
        var queue: PublicationQueue<Int>!
        queue = PublicationQueue { value in
            delivered.append(value)
            if value == 1 {
                queue.enqueue(2)
                queue.flush()
                delivered.append(-1)
            }
        }
        queue.enqueue(1)
        queue.flush()
        XCTAssertEqual(delivered, [1, -1, 2])
    }

    func testLatestOnlyCoalescesABatch() {
        var delivered: [Int] = []
        let queue = PublicationQueue<Int>(latestOnly: true) { delivered.append($0) }
        queue.enqueue(1)
        queue.enqueue(2)
        queue.enqueue(3)
        queue.flush()
        queue.flush()
        XCTAssertEqual(delivered, [3])
    }
}

final class DonkPersistenceTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        var name: String
        var values: [Int]
    }

    func testRoundTripInCustomDirectory() throws {
        let directory = makeTemporaryDirectory().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        XCTAssertNil(DonkPersistence.load(Sample.self, from: "sample.json", in: directory))
        DonkPersistence.save(Sample(name: "a", values: [1, 2]), to: "sample.json", in: directory)
        XCTAssertEqual(DonkPersistence.load(Sample.self, from: "sample.json", in: directory), Sample(name: "a", values: [1, 2]))
        DonkPersistence.save(Sample(name: "b", values: []), to: "sample.json", in: directory)
        XCTAssertEqual(DonkPersistence.load(Sample.self, from: "sample.json", in: directory)?.name, "b")
        XCTAssertNil(DonkPersistence.load([String].self, from: "sample.json", in: directory))
        DonkPersistence.remove("sample.json", in: directory)
        XCTAssertNil(DonkPersistence.load(Sample.self, from: "sample.json", in: directory))
    }

    func testDefaultDirectoryLocation() {
        let directory = DonkPersistence.directory
        XCTAssertEqual(directory.lastPathComponent, "Donk")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testLoadNeverCreatesDirectory() {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNil(DonkPersistence.load(Sample.self, from: "sample.json", in: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        DonkPersistence.save(Sample(name: "a", values: []), to: "sample.json", in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}

final class LazyStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        root = makeTemporaryDirectory()
        directory = root.appendingPathComponent("store", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var directoryExists: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    func testRuleStoreDoesNoIOUntilAccessed() {
        let store = RuleStore(fileName: "rules.json", directory: directory)
        XCTAssertFalse(directoryExists)
        let seeded = NetworkRule(name: "seeded", match: RuleMatch(url: URLMatcher(pattern: "example")), action: .breakpoint(request: true, response: false))
        RuleStore(fileName: "rules.json", directory: directory).add(seeded)
        XCTAssertTrue(directoryExists)
        XCTAssertEqual(store.rules.map(\.id), [seeded.id])
    }

    func testRuleStoreReadsDoNotCreateDirectory() {
        let store = RuleStore(fileName: "rules.json", directory: directory)
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.hasActiveRules)
        XCTAssertTrue(store.resolve(kind: .http, method: "GET", url: "https://example.com").isEmpty)
        _ = store.changes
        XCTAssertFalse(directoryExists)
        store.isEnabled = false
        XCTAssertTrue(directoryExists)
    }

    func testNetworkSettingsStoreDoesNoIOUntilAccessed() {
        let store = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        XCTAssertFalse(directoryExists)
        NetworkSettingsStore(fileName: "settings.json", directory: directory).update { $0.limit = 7 }
        XCTAssertTrue(directoryExists)
        XCTAssertEqual(store.settings.limit, 7)
    }

    func testNetworkSettingsStoreReadsDoNotCreateDirectory() {
        let store = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        let events = EventRecorder(store.changes)
        XCTAssertEqual(store.settings, .default)
        XCTAssertFalse(directoryExists)
        store.update { $0.limit = 9 }
        XCTAssertTrue(directoryExists)
        XCTAssertEqual(events.values.map(\.limit), [NetworkSettings.default.limit, 9])
    }

    func testChangesStartWithPersistedValue() {
        NetworkSettingsStore(fileName: "settings.json", directory: directory).update { $0.limit = 3 }
        let rule = NetworkRule(name: "stored", match: RuleMatch(url: URLMatcher(pattern: "example")), action: .breakpoint(request: true, response: false))
        RuleStore(fileName: "rules.json", directory: directory).add(rule)
        let settings = EventRecorder(NetworkSettingsStore(fileName: "settings.json", directory: directory).changes)
        let rules = EventRecorder(RuleStore(fileName: "rules.json", directory: directory).changes)
        XCTAssertEqual(settings.values.map(\.limit), [3])
        XCTAssertEqual(rules.values.map { $0.map(\.id) }, [[rule.id]])
    }
}

final class SwizzleTarget: NSObject {
    @objc dynamic func greet() -> String { "original" }
    @objc dynamic func swizzledGreet() -> String { "swizzled+" + swizzledGreet() }
    @objc dynamic class func make() -> String { "make" }
    @objc dynamic class func swizzledMake() -> String { "swizzled-make" }
}

class SwizzleBase: NSObject {
    @objc dynamic func name() -> String { "base" }
}

final class SwizzleChild: SwizzleBase {
    @objc dynamic func swizzledName() -> String { "child+" + swizzledName() }
}

final class DonkSwizzleTests: XCTestCase {
    func testInstanceMethodExchange() {
        XCTAssertTrue(DonkSwizzle.instanceMethod(SwizzleTarget.self, #selector(SwizzleTarget.greet), #selector(SwizzleTarget.swizzledGreet)))
        defer { DonkSwizzle.instanceMethod(SwizzleTarget.self, #selector(SwizzleTarget.greet), #selector(SwizzleTarget.swizzledGreet)) }
        XCTAssertEqual(SwizzleTarget().greet(), "swizzled+original")
    }

    func testInheritedMethodIsAddedToSubclassOnly() {
        XCTAssertTrue(DonkSwizzle.instanceMethod(SwizzleChild.self, #selector(SwizzleBase.name), #selector(SwizzleChild.swizzledName)))
        XCTAssertEqual(SwizzleChild().name(), "child+base")
        XCTAssertEqual(SwizzleBase().name(), "base")
    }

    func testClassMethodExchange() {
        XCTAssertTrue(DonkSwizzle.classMethod(SwizzleTarget.self, #selector(SwizzleTarget.make), #selector(SwizzleTarget.swizzledMake)))
        defer { DonkSwizzle.classMethod(SwizzleTarget.self, #selector(SwizzleTarget.make), #selector(SwizzleTarget.swizzledMake)) }
        XCTAssertEqual(SwizzleTarget.make(), "swizzled-make")
    }

    func testMissingSelectorsFail() {
        XCTAssertFalse(DonkSwizzle.instanceMethod(SwizzleTarget.self, NSSelectorFromString("doesNotExist"), #selector(SwizzleTarget.swizzledGreet)))
        XCTAssertFalse(DonkSwizzle.classMethod(SwizzleTarget.self, #selector(SwizzleTarget.make), NSSelectorFromString("nope")))
    }
}
