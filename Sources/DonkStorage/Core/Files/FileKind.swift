import Foundation

enum FileKind: String, Sendable, CaseIterable {
    case folder
    case text
    case json
    case plist
    case image
    case sqlite
    case pdf
    case video
    case audio
    case archive
    case document
    case binary

    var title: String {
        switch self {
        case .folder: return "Folder"
        case .text: return "Text"
        case .json: return "JSON"
        case .plist: return "Property list"
        case .image: return "Image"
        case .sqlite: return "SQLite database"
        case .pdf: return "PDF"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .document: return "Document"
        case .binary: return "Binary"
        }
    }

    var prefersQuickLook: Bool {
        switch self {
        case .pdf, .video, .audio, .archive, .document: return true
        default: return false
        }
    }

    static func guess(pathExtension: String) -> FileKind? {
        extensionMap[pathExtension.lowercased()]
    }

    static func detect(url: URL) -> FileKind {
        let header = readHeader(url, length: 4096)
        return detect(header: header, pathExtension: url.pathExtension)
    }

    static func detect(header: Data, pathExtension: String) -> FileKind {
        let guessed = guess(pathExtension: pathExtension)
        if header.isEmpty {
            return guessed == .json ? .json : (guessed == .plist ? .plist : .text)
        }
        if let magic = magicKind(header, guessed: guessed) {
            return magic
        }
        if guessed == .sqlite {
            return isLikelyText(header) ? .text : .binary
        }
        if let guessed, guessed != .text, guessed != .json, guessed != .plist {
            return guessed
        }
        guard isLikelyText(header) else {
            return guessed == .plist ? .plist : .binary
        }
        let prefix = String(decoding: header.prefix(1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.hasPrefix("<?xml") || prefix.hasPrefix("<!DOCTYPE plist") || prefix.hasPrefix("<plist") {
            if prefix.contains("<plist") || prefix.contains("PropertyList") {
                return .plist
            }
        }
        if guessed == .plist { return .plist }
        if guessed == .json { return .json }
        if prefix.hasPrefix("{") || prefix.hasPrefix("[") {
            return .json
        }
        return .text
    }

    static func readHeader(_ url: URL, length: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        if #available(iOS 13.4, *) {
            return (try? handle.read(upToCount: length)) ?? Data()
        }
        return handle.readData(ofLength: length)
    }

    static func isLikelyText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        if data.contains(0) { return false }
        var sample = data
        for _ in 0..<4 {
            if String(data: sample, encoding: .utf8) != nil { return true }
            guard !sample.isEmpty else { break }
            sample = sample.dropLast()
        }
        return false
    }

    private static func magicKind(_ header: Data, guessed: FileKind?) -> FileKind? {
        let bytes = [UInt8](header.prefix(32))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        if starts(Array("SQLite format 3".utf8) + [0]) { return .sqlite }
        if starts(Array("bplist0".utf8)) { return .plist }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || starts(Array("GIF8".utf8)) {
            return .image
        }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return .image }
        if starts(Array("RIFF".utf8)), starts(Array("WAVE".utf8), at: 8) { return .audio }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) || starts(Array("BM".utf8)) {
            return guessed == .image || guessed == nil ? .image : guessed
        }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts(Array("ftyp".utf8), at: 4), bytes.count >= 12 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "msf1", "heim", "heis", "avif"].contains(brand) { return .image }
            if brand.hasPrefix("M4A") { return .audio }
            return .video
        }
        if starts(Array("ID3".utf8)) || starts([0xFF, 0xFB]) || starts(Array("fLaC".utf8)) || starts(Array("caff".utf8)) {
            return .audio
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) {
            return guessed == .document ? .document : .archive
        }
        if starts([0x1F, 0x8B]) || starts(Array("7z".utf8) + [0xBC, 0xAF]) || starts(Array("Rar!".utf8)) {
            return .archive
        }
        return nil
    }

    private static let extensionMap: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        let groups: [(FileKind, [String])] = [
            (.json, ["json", "geojson", "har", "jsonc", "webmanifest"]),
            (.text, [
                "txt", "text", "md", "markdown", "log", "csv", "tsv", "xml", "html", "htm", "css", "js", "ts",
                "swift", "m", "h", "c", "cpp", "kt", "java", "py", "rb", "sh", "yml", "yaml", "ini", "conf",
                "cfg", "toml", "sql", "svg", "env", "gitignore", "jsonl", "ndjson", "proto", "graphql", "lock",
            ]),
            (.plist, ["plist", "strings", "stringsdict", "entitlements", "mobileprovision"]),
            (.image, ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "ico", "avif"]),
            (.sqlite, ["sqlite", "sqlite3", "db", "sqlitedb", "db3"]),
            (.pdf, ["pdf"]),
            (.video, ["mp4", "mov", "m4v", "3gp", "avi", "mkv"]),
            (.audio, ["mp3", "m4a", "wav", "aac", "caf", "aiff", "aif", "flac", "ogg", "opus"]),
            (.archive, ["zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar"]),
            (.document, ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "usdz", "reality", "epub"]),
        ]
        for (kind, extensions) in groups {
            for item in extensions {
                map[item] = kind
            }
        }
        return map
    }()
}
