import Donk
import Foundation
import Security
import SQLite3
import UIKit

enum StorageSampleData {
    static let suiteName = "group.donk.demo.suite"
    static let keyPrefix = "demo."

    private static let documentItems = [
        "sample.json", "notes.txt", "config.plist", "settings.plist", "gradient.png", "library.sqlite", "Projects", "Bulk",
    ]
    private static let cacheFolder = "donk-demo"
    private static let keychainService = "io.github.dimashbk.donkdemo.session"
    private static let protectedService = "io.github.dimashbk.donkdemo.biometric"
    private static let keychainServer = "api.donk.example"
    private static let cookieDomains = ["donk.example", "api.donk.example"]

    static func configureDonkStorage() {
        var configuration = StorageConfiguration()
        configuration.userDefaultsSuites = [suiteName]
        configuration.appGroupIdentifiers = ["group.io.github.dimashbk.donkdemo"]
        DonkStorage.configure(configuration)
    }

    // MARK: - Seed

    static func seed() throws -> String {
        let manager = FileManager.default
        let documents = try directory(.documentDirectory)
        let caches = try directory(.cachesDirectory)

        try sampleJSON.write(to: documents.appendingPathComponent("sample.json"), atomically: true, encoding: .utf8)
        try notes.write(to: documents.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try PropertyListSerialization.data(fromPropertyList: configPlist, format: .xml, options: 0)
            .write(to: documents.appendingPathComponent("config.plist"), options: .atomic)
        try PropertyListSerialization.data(fromPropertyList: settingsPlist, format: .binary, options: 0)
            .write(to: documents.appendingPathComponent("settings.plist"), options: .atomic)
        try gradientPNG().write(to: documents.appendingPathComponent("gradient.png"), options: .atomic)
        try createDatabase(at: documents.appendingPathComponent("library.sqlite"))

        let projects = documents.appendingPathComponent("Projects", isDirectory: true)
        let quarter = projects.appendingPathComponent("2026/Q4", isDirectory: true)
        let archive = projects.appendingPathComponent("Archive", isDirectory: true)
        try manager.createDirectory(at: quarter, withIntermediateDirectories: true)
        try manager.createDirectory(at: archive, withIntermediateDirectories: true)
        try "# Q4 report\n\n- Revenue: 1.2M\n- Users: 48K\n".write(to: quarter.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try #"{"draft":true,"owner":"aruzhan"}"#.write(to: quarter.appendingPathComponent("draft.json"), atomically: true, encoding: .utf8)
        try (0..<200).map { "2026-09-\(String(format: "%02d", $0 % 30 + 1)) INFO request #\($0) completed" }
            .joined(separator: "\n")
            .write(to: archive.appendingPathComponent("old.log"), atomically: true, encoding: .utf8)
        try Data((0..<2048).map { UInt8($0 % 251) }).write(to: archive.appendingPathComponent("blob.bin"))
        try "hidden".write(to: projects.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)

        let cacheDirectory = caches.appendingPathComponent(cacheFolder, isDirectory: true)
        let images = cacheDirectory.appendingPathComponent("images", isDirectory: true)
        try manager.createDirectory(at: images, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Data((0..<(1024 * (index + 1))).map { _ in UInt8.random(in: 0...255) })
                .write(to: images.appendingPathComponent("thumb-\(index).dat"))
        }
        try #"{"etag":"W/\"42\"","maxAge":3600,"entries":12}"#
            .write(to: cacheDirectory.appendingPathComponent("http-cache.json"), atomically: true, encoding: .utf8)

        seedDefaults(UserDefaults.standard)
        if let suite = UserDefaults(suiteName: suiteName) {
            seedDefaults(suite)
            suite.set("suite-only", forKey: keyPrefix + "suiteMarker")
        }
        let keychain = seedKeychain()
        seedCookies()
        return "Seeded files, defaults, cookies" + (keychain ? " and keychain" : " (keychain unavailable)")
    }

    static func seedBulkFiles(count: Int) throws -> String {
        let bulk = try directory(.documentDirectory).appendingPathComponent("Bulk", isDirectory: true)
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for index in 0..<count {
            let name = String(format: "item-%04d.txt", index)
            try Data("Bulk file \(index)\n".utf8).write(to: bulk.appendingPathComponent(name))
        }
        for index in 0..<20 {
            let folder = bulk.appendingPathComponent(String(format: "folder-%02d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 512 * (index + 1)).write(to: folder.appendingPathComponent("payload.bin"))
        }
        return "Created \(count) files and 20 folders in Documents/Bulk"
    }

    static func seedProtectedKeychainItem() throws -> String {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: protectedService,
        ] as CFDictionary)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "StorageSampleData", code: 3)
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: protectedService,
            kSecAttrAccount as String: "biometry-key",
            kSecAttrLabel as String: "Biometric-bound token (.userPresence)",
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data("biometric-secret-\(Int(Date().timeIntervalSince1970))".utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
            throw NSError(domain: "StorageSampleData", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(message) (\(status))"])
        }
        return "Added “biometry-key” protected by .userPresence. Listing must not prompt."
    }

    // MARK: - Clear

    static func clear() -> String {
        let manager = FileManager.default
        if let documents = try? directory(.documentDirectory) {
            for name in documentItems {
                try? manager.removeItem(at: documents.appendingPathComponent(name))
            }
        }
        if let caches = try? directory(.cachesDirectory) {
            try? manager.removeItem(at: caches.appendingPathComponent(cacheFolder))
        }
        clearDefaults(UserDefaults.standard)
        if let suite = UserDefaults(suiteName: suiteName) {
            clearDefaults(suite)
        }
        clearKeychain()
        let storage = HTTPCookieStorage.shared
        storage.cookies?
            .filter { cookie in cookieDomains.contains { cookie.domain.hasSuffix($0) } }
            .forEach(storage.deleteCookie)
        return "Sample data removed"
    }

    // MARK: - Defaults

    private static func seedDefaults(_ defaults: UserDefaults) {
        defaults.set("Aruzhan", forKey: keyPrefix + "userName")
        defaults.set("Line one\nLine two", forKey: keyPrefix + "multiline")
        defaults.set(42, forKey: keyPrefix + "launchCount")
        defaults.set(1, forKey: keyPrefix + "onboardingStep")
        defaults.set(3.14159, forKey: keyPrefix + "pi")
        defaults.set(true, forKey: keyPrefix + "isPremium")
        defaults.set(false, forKey: keyPrefix + "hasSeenTour")
        defaults.set(Date(), forKey: keyPrefix + "lastSync")
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42]), forKey: keyPrefix + "pushToken")
        defaults.set(["ru", "kk", "en"], forKey: keyPrefix + "languages")
        defaults.set(["theme": "dark", "fontScale": 1.2, "beta": true, "tabs": ["home", "cards"]] as [String: Any], forKey: keyPrefix + "settings")
        defaults.set(["installedAt": Date(), "receipt": Data([1, 2, 3])], forKey: keyPrefix + "install")
    }

    private static func clearDefaults(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keychain

    private static func seedKeychain() -> Bool {
        clearKeychain()
        let token = #"{"access_token":"eyJhbGciOiJIUzI1NiJ9.demo","refresh_token":"r-7f3a","expires_in":3600}"#
        let generic: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "aruzhan@donk.example",
            kSecAttrLabel as String: "Session tokens",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(token.utf8),
        ]
        let internet: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainServer,
            kSecAttrAccount as String: "demo-client",
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrPort as String: 443,
            kSecAttrPath as String: "/v1",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data([0x00, 0x01, 0x02, 0xFA, 0xFB, 0xFC, 0x7F, 0x80]),
        ]
        let first = SecItemAdd(generic as CFDictionary, nil)
        let second = SecItemAdd(internet as CFDictionary, nil)
        return first == errSecSuccess && second == errSecSuccess
    }

    private static func clearKeychain() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainServer,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: protectedService,
        ] as CFDictionary)
    }

    // MARK: - Cookies

    private static func seedCookies() {
        let storage = HTTPCookieStorage.shared
        let cookies: [[HTTPCookiePropertyKey: Any]] = [
            [.domain: ".donk.example", .path: "/", .name: "session", .value: "s%3Aa1b2c3d4e5f6", .secure: "TRUE",
             HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue],
            [.domain: "donk.example", .path: "/", .name: "theme", .value: "dark",
             .expires: Date().addingTimeInterval(86_400 * 30)],
            [.domain: "api.donk.example", .path: "/v1", .name: "csrf_token", .value: "9f86d081884c7d659a2feaa0c55ad015",
             .secure: "TRUE", .expires: Date().addingTimeInterval(3600), .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict.rawValue],
            [.domain: "api.donk.example", .path: "/", .name: "ab_bucket", .value: "B", .expires: Date().addingTimeInterval(86_400 * 7)],
        ]
        cookies.compactMap(HTTPCookie.init).forEach(storage.setCookie)
    }

    // MARK: - Files

    private static func directory(_ kind: FileManager.SearchPathDirectory) throws -> URL {
        let url = try FileManager.default.url(for: kind, in: .userDomainMask, appropriateFor: nil, create: true)
        return url
    }

    private static func gradientPNG() -> Data {
        let size = CGSize(width: 600, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.pngData { context in
            let colors = [
                UIColor(red: 0.43, green: 0.36, blue: 0.99, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.58, blue: 0.53, alpha: 1).cgColor,
                UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = "donk" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }
    }

    private static func createDatabase(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "StorageSampleData", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the SQLite database"])
        }
        defer { sqlite3_close(database) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(database))
                throw NSError(domain: "StorageSampleData", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        let cities = ["Almaty", "Astana", "Shymkent", "Karaganda", "Aktobe", "Taraz"]
        let names = ["Aruzhan", "Dias", "Madina", "Timur", "Aigerim", "Nursultan", "Dana", "Arman"]
        try exec("""
            CREATE TABLE customers (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                email TEXT,
                city TEXT,
                balance REAL,
                avatar BLOB,
                created_at TEXT
            )
            """)
        try exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), amount REAL, status TEXT, note TEXT)")
        try exec("BEGIN")
        for index in 1...500 {
            let name = names[index % names.count] + " \(index)"
            let email = index % 7 == 0 ? "NULL" : "'user\(index)@donk.example'"
            let balance = Double(index * 137 % 100_000) / 10
            try exec("INSERT INTO customers VALUES (\(index), '\(name)', \(email), '\(cities[index % cities.count])', \(balance), x'89504E47', '2026-09-\(String(format: "%02d", index % 30 + 1))T10:00:00Z')")
        }
        for index in 1...250 {
            let status = ["paid", "pending", "refunded"][index % 3]
            try exec("INSERT INTO orders VALUES (\(index), \(index * 2 % 500 + 1), \(Double(index) * 12.5), '\(status)', \(index % 5 == 0 ? "'gift wrap'" : "NULL"))")
        }
        try exec("COMMIT")
    }

    // MARK: - Contents

    private static let sampleJSON = """
        {
          "user": {
            "id": 1024,
            "name": "Aruzhan",
            "email": "aruzhan@donk.example",
            "verified": true,
            "roles": ["admin", "beta"],
            "limits": { "daily": 500000, "currency": "KZT" }
          },
          "accounts": [
            { "id": "KZ12-3456", "type": "card", "balance": 125000.5, "frozen": false },
            { "id": "KZ98-7654", "type": "deposit", "balance": 2400000, "rate": 0.14 }
          ],
          "featureFlags": { "newTransfers": true, "aiAssistant": false },
          "lastLogin": "2026-10-01T09:41:00Z",
          "metadata": null
        }
        """

    private static let notes = """
        donk demo notes
        ===============

        This file lives in Documents/notes.txt.
        Open it in the storage browser, tap Edit, change something and Save.
        The file is written atomically.
        """

    private static var configPlist: [String: Any] {
        [
            "apiBaseURL": "https://api.donk.example/v1",
            "timeout": 30,
            "retryPolicy": ["maxAttempts": 3, "backoff": 1.5] as [String: Any],
            "enabledModules": ["network", "storage", "push"],
            "debug": true,
        ]
    }

    private static var settingsPlist: [String: Any] {
        [
            "lastOpened": Date(),
            "avatarHash": Data([0x9F, 0x86, 0xD0, 0x81, 0x88, 0x4C]),
            "volume": 0.8,
            "notifications": ["marketing": false, "transactions": true],
            "recentSearches": ["coffee", "taxi", "groceries"],
        ]
    }
}
