import Foundation
import LocalAuthentication
import Security

enum KeychainItemClass: String, CaseIterable, Hashable, Sendable {
    case genericPassword
    case internetPassword

    var secClass: CFString {
        switch self {
        case .genericPassword: return kSecClassGenericPassword
        case .internetPassword: return kSecClassInternetPassword
        }
    }

    var title: String {
        switch self {
        case .genericPassword: return "Generic passwords"
        case .internetPassword: return "Internet passwords"
        }
    }

    var shortTitle: String {
        switch self {
        case .genericPassword: return "Generic password"
        case .internetPassword: return "Internet password"
        }
    }
}

struct KeychainItem: Identifiable, Hashable, Sendable {
    let itemClass: KeychainItemClass
    let service: String?
    let account: String?
    let server: String?
    let label: String?
    let comment: String?
    let itemDescription: String?
    let accessGroup: String?
    let accessible: String?
    let protocolName: String?
    let authenticationType: String?
    let securityDomain: String?
    let path: String?
    let port: Int?
    let created: Date?
    let modified: Date?
    let isSynchronizable: Bool
    let persistentRef: Data?

    var id: String {
        if let persistentRef { return persistentRef.base64EncodedString() }
        return [itemClass.rawValue, service, account, server, accessGroup, path, port.map(String.init)]
            .map { $0 ?? "" }
            .joined(separator: "|")
    }

    var title: String {
        let candidates = itemClass == .internetPassword ? [server, label, account] : [service, label, account]
        return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled item"
    }

    var subtitle: String? {
        let primary = itemClass == .internetPassword ? server : service
        if let account, !account.isEmpty, account != title { return account }
        if let label, !label.isEmpty, label != title, label != primary { return label }
        return nil
    }

    var accessibilityDescription: String? {
        accessible.map(KeychainStore.describeAccessible)
    }

    var isEditable: Bool {
        itemClass == .genericPassword
    }
}

enum KeychainError: LocalizedError, Equatable {
    case missingEntitlement
    case interactionNotAllowed
    case userCanceled
    case authenticationFailed
    case status(OSStatus)

    var status: OSStatus {
        switch self {
        case .missingEntitlement: return errSecMissingEntitlement
        case .interactionNotAllowed: return errSecInteractionNotAllowed
        case .userCanceled: return errSecUserCanceled
        case .authenticationFailed: return errSecAuthFailed
        case let .status(status): return status
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingEntitlement:
            return "The app has no keychain access entitlement in this environment."
        case .interactionNotAllowed:
            return "The keychain is locked. Unlock the device and try again."
        case .userCanceled:
            return "Authentication was cancelled."
        case .authenticationFailed:
            return "Authentication failed."
        case let .status(status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return (message ?? "Keychain error") + " (\(status))"
        }
    }

    init(_ status: OSStatus) {
        switch status {
        case errSecMissingEntitlement: self = .missingEntitlement
        case errSecInteractionNotAllowed: self = .interactionNotAllowed
        case errSecUserCanceled: self = .userCanceled
        case errSecAuthFailed: self = .authenticationFailed
        default: self = .status(status)
        }
    }
}

enum KeychainValueLookup: Equatable, Sendable {
    case value(Data)
    case missing
    case requiresAuthentication
}

enum KeychainAuthentication: Equatable, Sendable {
    case never
    case prompt(reason: String)
}

enum KeychainStore {
    static func items() throws -> [KeychainItem] {
        var result: [KeychainItem] = []
        for itemClass in KeychainItemClass.allCases {
            result += try items(of: itemClass)
        }
        return result
    }

    static func items(of itemClass: KeychainItemClass) throws -> [KeychainItem] {
        let query: [String: Any] = [
            kSecClass as String: itemClass.secClass,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseAuthenticationContext as String: nonInteractiveContext(),
        ]
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError(status)
        }
        let dictionaries = (output as? [[String: Any]]) ?? (output as? [String: Any]).map { [$0] } ?? []
        return dictionaries.map { makeItem(itemClass, $0) }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order == .orderedSame { return (lhs.account ?? "") < (rhs.account ?? "") }
                return order == .orderedAscending
            }
    }

    static func value(for item: KeychainItem, authentication: KeychainAuthentication = .never) throws -> KeychainValueLookup {
        var query = matchQuery(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch authentication {
        case .never:
            query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        case let .prompt(reason):
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
        }
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        switch status {
        case errSecSuccess:
            return (output as? Data).map(KeychainValueLookup.value) ?? .missing
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed:
            guard authentication == .never else { throw KeychainError(status) }
            return .requiresAuthentication
        default:
            throw KeychainError(status)
        }
    }

    static func item(matching item: KeychainItem) throws -> KeychainItem? {
        try items(of: item.itemClass).first { $0.id == item.id }
    }

    static func updateValue(_ value: Data, for item: KeychainItem) throws {
        let status = SecItemUpdate(matchQuery(for: item) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    static func delete(_ item: KeychainItem) throws {
        let status = SecItemDelete(matchQuery(for: item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    static func addGenericPassword(service: String, account: String, value: Data, label: String? = nil) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let label {
            attributes[kSecAttrLabel as String] = label
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    static func text(from data: Data) -> String? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let allowed = CharacterSet(charactersIn: "\n\r\t")
        let hasControl = string.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && !allowed.contains(scalar)
        }
        return hasControl ? nil : string
    }

    static func describeAccessible(_ raw: String) -> String {
        let names: [String: String] = [
            kSecAttrAccessibleWhenUnlocked as String: "When unlocked",
            kSecAttrAccessibleAfterFirstUnlock as String: "After first unlock",
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String: "When passcode set, this device only",
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String: "When unlocked, this device only",
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String: "After first unlock, this device only",
            "dk": "Always (deprecated)",
            "dku": "Always, this device only (deprecated)",
        ]
        return names[raw] ?? raw
    }

    // MARK: - Private

    private static func nonInteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func matchQuery(for item: KeychainItem) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: item.itemClass.secClass,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let persistentRef = item.persistentRef {
            query[kSecValuePersistentRef as String] = persistentRef
            return query
        }
        let pairs: [(CFString, Any?)] = [
            (kSecAttrService, item.service),
            (kSecAttrAccount, item.account),
            (kSecAttrServer, item.server),
            (kSecAttrAccessGroup, item.accessGroup),
            (kSecAttrPath, item.path),
            (kSecAttrPort, item.port),
            (kSecAttrSecurityDomain, item.securityDomain),
        ]
        for (key, value) in pairs {
            if let value {
                query[key as String] = value
            }
        }
        return query
    }

    private static func makeItem(_ itemClass: KeychainItemClass, _ attributes: [String: Any]) -> KeychainItem {
        func string(_ key: CFString) -> String? {
            let value = attributes[key as String]
            if let string = value as? String { return string }
            if let data = value as? Data {
                return String(data: data, encoding: .utf8) ?? HexDump.hex(data, grouped: false)
            }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue
            ?? ((attributes[kSecAttrSynchronizable as String] as? String) == "1")
        return KeychainItem(
            itemClass: itemClass,
            service: string(kSecAttrService),
            account: string(kSecAttrAccount),
            server: string(kSecAttrServer),
            label: string(kSecAttrLabel),
            comment: string(kSecAttrComment),
            itemDescription: string(kSecAttrDescription),
            accessGroup: string(kSecAttrAccessGroup),
            accessible: string(kSecAttrAccessible),
            protocolName: string(kSecAttrProtocol),
            authenticationType: string(kSecAttrAuthenticationType),
            securityDomain: string(kSecAttrSecurityDomain),
            path: string(kSecAttrPath),
            port: (attributes[kSecAttrPort as String] as? NSNumber)?.intValue,
            created: attributes[kSecAttrCreationDate as String] as? Date,
            modified: attributes[kSecAttrModificationDate as String] as? Date,
            isSynchronizable: synchronizable,
            persistentRef: attributes[kSecValuePersistentRef as String] as? Data
        )
    }
}
