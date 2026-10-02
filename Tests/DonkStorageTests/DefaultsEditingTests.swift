import XCTest
@testable import DonkStorage

@MainActor
final class DefaultsEditingTests: XCTestCase {
    private var domain: DefaultsDomain!

    override func setUp() async throws {
        try await super.setUp()
        domain = .suite("dev.donk.tests.editing." + UUID().uuidString)
    }

    override func tearDown() async throws {
        DefaultsStore.reset(domain)
        try await super.tearDown()
    }

    func testStringEditsAreWrittenOnlyOnSave() {
        DefaultsStore.set("before", forKey: "name", in: domain)
        let model = DefaultsEditorModel(domain: domain, key: "name")
        model.stringValue = "a"
        model.stringValue = "af"
        model.stringValue = "after"
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(DefaultsStore.value(forKey: "name", in: domain) as? String, "before")
        XCTAssertTrue(model.save())
        XCTAssertEqual(DefaultsStore.value(forKey: "name", in: domain) as? String, "after")
        XCTAssertFalse(model.hasChanges)
    }

    func testCancelRevertsDraft() {
        DefaultsStore.set(true, forKey: "flag", in: domain)
        let model = DefaultsEditorModel(domain: domain, key: "flag")
        model.boolValue = false
        XCTAssertTrue(model.hasChanges)
        model.cancel()
        XCTAssertTrue(model.boolValue)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(DefaultsStore.value(forKey: "flag", in: domain) as? Bool, true)
    }

    func testInvalidNumberIsNotSaved() {
        DefaultsStore.set(42, forKey: "count", in: domain)
        let model = DefaultsEditorModel(domain: domain, key: "count")
        model.numberText = "4x"
        XCTAssertEqual(model.validationError, "Enter a whole number")
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.save())
        XCTAssertEqual((DefaultsStore.value(forKey: "count", in: domain) as? NSNumber)?.intValue, 42)
        model.numberText = " 43 "
        XCTAssertTrue(model.save())
        XCTAssertEqual((DefaultsStore.value(forKey: "count", in: domain) as? NSNumber)?.intValue, 43)
    }

    func testInvalidJSONKeepsStoredCollection() {
        DefaultsStore.set(["a", "b"], forKey: "list", in: domain)
        let model = DefaultsEditorModel(domain: domain, key: "list")
        model.jsonText = "[\"a\","
        XCTAssertFalse(model.save())
        XCTAssertEqual(model.jsonError, "Invalid JSON")
        XCTAssertEqual(DefaultsStore.value(forKey: "list", in: domain) as? [String], ["a", "b"])
        model.jsonText = "[\"c\"]"
        XCTAssertNil(model.jsonError)
        XCTAssertTrue(model.save())
        XCTAssertEqual(DefaultsStore.value(forKey: "list", in: domain) as? [String], ["c"])
    }

    func testListObservesChangesOnlyWhileVisible() async {
        let model = DefaultsListModel(domain: domain)
        XCTAssertFalse(model.isObservingChanges)
        DefaultsStore.set("v", forKey: "k", in: domain)
        model.becameVisible()
        XCTAssertTrue(model.isObservingChanges)
        await model.reloadNow()
        XCTAssertEqual(model.entries.map(\.key), ["k"])
        model.becameHidden()
        XCTAssertFalse(model.isObservingChanges)
    }

    func testPreferencesFileDomain() {
        let library = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Library/Preferences", isDirectory: true)
        XCTAssertEqual(
            PreferencesFile.domain(for: library.appendingPathComponent("com.bank.app.plist"), bundleIdentifier: "com.bank.app"),
            DefaultsDomain(kind: .standard, name: "com.bank.app")
        )
        XCTAssertEqual(
            PreferencesFile.domain(for: library.appendingPathComponent("group.com.bank.shared.plist"), bundleIdentifier: "com.bank.app"),
            .suite("group.com.bank.shared")
        )
        XCTAssertNil(PreferencesFile.domain(for: library.appendingPathComponent("notes.txt"), bundleIdentifier: "com.bank.app"))
        XCTAssertNil(PreferencesFile.domain(
            for: URL(fileURLWithPath: "/tmp/Documents/config.plist"),
            bundleIdentifier: "com.bank.app"
        ))
    }
}
