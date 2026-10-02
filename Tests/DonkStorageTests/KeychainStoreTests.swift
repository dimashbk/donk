import Security
import XCTest
@testable import DonkStorage

final class KeychainStoreTests: XCTestCase {
    private let service = "dev.donk.tests.keychain." + UUID().uuidString

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    func testAddListUpdateDelete() throws {
        do {
            try KeychainStore.addGenericPassword(service: service, account: "alice", value: Data("s3cret".utf8), label: "Test item")
        } catch let error as KeychainError {
            throw XCTSkip("Keychain is unavailable in this test host: \(error.localizedDescription)")
        }

        var item = try XCTUnwrap(try KeychainStore.items(of: .genericPassword).first { $0.service == service })
        XCTAssertEqual(item.account, "alice")
        XCTAssertEqual(item.label, "Test item")
        XCTAssertEqual(try KeychainStore.value(for: item), .value(Data("s3cret".utf8)))
        XCTAssertEqual(item.title, service)
        XCTAssertEqual(item.subtitle, "alice")
        XCTAssertEqual(item.accessibilityDescription, "After first unlock")
        XCTAssertNotNil(item.created)
        XCTAssertTrue(item.isEditable)

        try KeychainStore.updateValue(Data([0x00, 0xFF]), for: item)
        item = try XCTUnwrap(try KeychainStore.item(matching: item))
        XCTAssertEqual(try KeychainStore.value(for: item), .value(Data([0x00, 0xFF])))

        try KeychainStore.delete(item)
        XCTAssertNil(try KeychainStore.items(of: .genericPassword).first { $0.service == service })
        XCTAssertNoThrow(try KeychainStore.delete(item))
    }

    func testListingSkipsDataOfAccessControlledItemsWithoutPrompting() throws {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) else {
            throw XCTSkip("SecAccessControl is unavailable")
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "biometry-key",
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data("guarded".utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw XCTSkip("Can't add an access-controlled item in this test host (\(status))")
        }

        let items = try KeychainStore.items(of: .genericPassword).filter { $0.service == service }
        let item = try XCTUnwrap(items.first { $0.account == "biometry-key" })
        XCTAssertEqual(try KeychainStore.value(for: item, authentication: .never), .requiresAuthentication)
        XCTAssertEqual(KeychainError(errSecUserCanceled), .userCanceled)
        XCTAssertEqual(KeychainError(errSecAuthFailed), .authenticationFailed)
    }

    func testTextDetectionAndErrors() {
        XCTAssertEqual(KeychainStore.text(from: Data("line\nnext".utf8)), "line\nnext")
        XCTAssertNil(KeychainStore.text(from: Data([0x01, 0x41])))
        XCTAssertNil(KeychainStore.text(from: Data([0xFF, 0xFE])))
        XCTAssertEqual(KeychainError(errSecMissingEntitlement), .missingEntitlement)
        XCTAssertEqual(KeychainError(errSecItemNotFound).status, errSecItemNotFound)
        XCTAssertNotNil(KeychainError.missingEntitlement.errorDescription)
        XCTAssertEqual(KeychainStore.describeAccessible("dku"), "Always, this device only (deprecated)")
    }
}
