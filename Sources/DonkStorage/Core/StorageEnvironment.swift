import DonkCore
import Foundation

final class StorageEnvironment: @unchecked Sendable {
    static let shared = StorageEnvironment()

    private let lock = DonkLock()
    private var storedConfiguration = StorageConfiguration()

    var configuration: StorageConfiguration {
        get { lock.withLock { storedConfiguration } }
        set { lock.withLock { storedConfiguration = newValue } }
    }
}

// MARK: - Locations

struct StorageLocation: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case sandbox
        case documents
        case library
        case caches
        case temporary
        case appGroup(String)
    }

    let kind: Kind
    let url: URL

    var id: String { url.path }

    var title: String {
        switch kind {
        case .sandbox: return "App sandbox"
        case .documents: return "Documents"
        case .library: return "Library"
        case .caches: return "Caches"
        case .temporary: return "tmp"
        case let .appGroup(identifier): return identifier
        }
    }
}

enum StorageLocations {
    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static func standard() -> [StorageLocation] {
        let manager = FileManager.default
        var result = [StorageLocation(kind: .sandbox, url: home)]
        if let url = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            result.append(StorageLocation(kind: .documents, url: url))
        }
        if let url = manager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            result.append(StorageLocation(kind: .library, url: url))
        }
        if let url = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            result.append(StorageLocation(kind: .caches, url: url))
        }
        result.append(StorageLocation(kind: .temporary, url: manager.temporaryDirectory))
        return result
    }

    static func appGroups(_ identifiers: [String]) -> [StorageLocation] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted,
                  let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return StorageLocation(kind: .appGroup(identifier), url: url)
        }
    }

    static var donkDirectories: [URL] {
        let manager = FileManager.default
        var result: [URL] = []
        if let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            result.append(support.appendingPathComponent("Donk", isDirectory: true))
        }
        result.append(manager.temporaryDirectory.appendingPathComponent("DonkShare", isDirectory: true))
        return result
    }

    static var protectedPaths: Set<String> {
        Set(donkDirectories.map(canonicalPath))
    }

    static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func isProtected(_ url: URL) -> Bool {
        isProtected(canonicalPath: canonicalPath(url), roots: protectedPaths)
    }

    static func isProtected(canonicalPath path: String, roots: Set<String>) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func displayPath(_ url: URL) -> String {
        let homePath = canonicalPath(home)
        let path = canonicalPath(url)
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}
