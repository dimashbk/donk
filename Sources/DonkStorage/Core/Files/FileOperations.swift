import Foundation
import UniformTypeIdentifiers

struct FileOperationError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

enum FileOperations {
    static func validateName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Name can't be empty" }
        if trimmed == "." || trimmed == ".." { return "Name is reserved" }
        if trimmed.contains("/") || trimmed.contains(":") { return "Name can't contain / or :" }
        if trimmed.utf8.count > 255 { return "Name is too long" }
        return nil
    }

    @discardableResult
    static func createFolder(named name: String, in directory: URL) throws -> URL {
        let url = try destination(named: name, in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    static func createTextFile(named name: String, in directory: URL, contents: String = "") throws -> URL {
        let url = try destination(named: name, in: directory)
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let target = try destination(named: newName, in: url.deletingLastPathComponent(), allowing: url)
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    static func writeText(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let preserved = (try? manager.attributesOfItem(atPath: url.path))?.filter { key, _ in
            key == .posixPermissions || key == .protectionKey
        }
        try data.write(to: url, options: .atomic)
        if let preserved, !preserved.isEmpty {
            try? manager.setAttributes(preserved, ofItemAtPath: url.path)
        }
    }

    private static func destination(named name: String, in directory: URL, allowing existing: URL? = nil) throws -> URL {
        if let message = validateName(name) {
            throw FileOperationError(message: message)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = directory.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: url.path) {
            let isSameItem = existing.map { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? false
            let isCaseChange = existing.map { $0.lastPathComponent.lowercased() == trimmed.lowercased() } ?? false
            if !isSameItem && !isCaseChange {
                throw FileOperationError(message: "“\(trimmed)” already exists")
            }
        }
        return url
    }
}

// MARK: - Info

struct FileInfo: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let kind: FileKind
    let isSymbolicLink: Bool
    let symlinkDestination: String?
    let size: Int64?
    let created: Date?
    let modified: Date?
    let protection: String?
    let typeDescription: String?
    let isHidden: Bool
    let isExcludedFromBackup: Bool?
    let attributes: [(String, String)]

    static func load(_ url: URL) -> FileInfo {
        let manager = FileManager.default
        let attributes = (try? manager.attributesOfItem(atPath: url.path)) ?? [:]
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .isHiddenKey, .isExcludedFromBackupKey, .fileProtectionKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isLink = values?.isSymbolicLink ?? false
        var isDirectory = values?.isDirectory ?? false
        if isLink {
            isDirectory = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        let size: Int64? = isDirectory ? FolderSizeCache.shared.cachedSize(of: url) : Int64(values?.fileSize ?? 0)
        var protection = (attributes[.protectionKey] as? FileProtectionType).map(describe)
        if protection == nil, let urlProtection = values?.fileProtection {
            protection = describe(FileProtectionType(rawValue: urlProtection.rawValue))
        }
        let destination = isLink ? (try? manager.destinationOfSymbolicLink(atPath: url.path)) : nil
        return FileInfo(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            kind: isDirectory ? .folder : FileKind.detect(url: url),
            isSymbolicLink: isLink,
            symlinkDestination: destination,
            size: size,
            created: values?.creationDate ?? attributes[.creationDate] as? Date,
            modified: values?.contentModificationDate ?? attributes[.modificationDate] as? Date,
            protection: protection,
            typeDescription: typeDescription(url, isDirectory: isDirectory),
            isHidden: (values?.isHidden ?? false) || url.lastPathComponent.hasPrefix("."),
            isExcludedFromBackup: values?.isExcludedFromBackup,
            attributes: describe(attributes)
        )
    }

    static func describe(_ protection: FileProtectionType) -> String {
        switch protection {
        case .complete: return "Complete"
        case .completeUnlessOpen: return "Complete unless open"
        case .completeUntilFirstUserAuthentication: return "Until first user authentication"
        case .none: return "None"
        default:
            if #available(iOS 17, *), protection == .completeWhenUserInactive {
                return "Complete when user inactive"
            }
            return protection.rawValue
        }
    }

    private static func typeDescription(_ url: URL, isDirectory: Bool) -> String? {
        if isDirectory { return "Folder" }
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return type.localizedDescription ?? type.identifier
    }

    private static func describe(_ attributes: [FileAttributeKey: Any]) -> [(String, String)] {
        let names: [FileAttributeKey: String] = [
            .type: "Type",
            .size: "Size (bytes)",
            .posixPermissions: "Permissions",
            .ownerAccountName: "Owner",
            .groupOwnerAccountName: "Group",
            .ownerAccountID: "Owner ID",
            .groupOwnerAccountID: "Group ID",
            .referenceCount: "Links",
            .systemNumber: "Device",
            .systemFileNumber: "Inode",
            .creationDate: "Created",
            .modificationDate: "Modified",
            .protectionKey: "Protection",
            .extensionHidden: "Extension hidden",
            .immutable: "Immutable",
            .appendOnly: "Append only",
            .busy: "Busy",
        ]
        return attributes.compactMap { key, value -> (String, String)? in
            let name = names[key] ?? key.rawValue.replacingOccurrences(of: "NSFile", with: "")
            return (name, format(key, value))
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private static func format(_ key: FileAttributeKey, _ value: Any) -> String {
        if key == .posixPermissions, let number = value as? NSNumber {
            return String(format: "%03o", number.intValue) + " (" + permissionString(number.intValue) + ")"
        }
        if key == .type, let type = value as? FileAttributeType {
            return type.rawValue.replacingOccurrences(of: "NSFileType", with: "")
        }
        if key == .protectionKey, let protection = value as? FileProtectionType {
            return describe(protection)
        }
        if let date = value as? Date {
            return StorageFormat.dateTime(date)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return number.boolValue ? "Yes" : "No"
            }
            return number.stringValue
        }
        return "\(value)"
    }

    private static func permissionString(_ mode: Int) -> String {
        let symbols: [Character] = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 8, through: 0, by: -1) {
            result.append(mode & (1 << shift) != 0 ? symbols[(8 - shift) % 3] : "-")
        }
        return result
    }
}

// MARK: - Formatting

enum StorageFormat {
    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
