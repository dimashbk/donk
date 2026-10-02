import DonkCore
import Foundation
import UniformTypeIdentifiers
import UserNotifications

struct PushAttachmentResult {
    var attachment: UNNotificationAttachment
    var sourceURL: URL
    var mimeType: String?
    var byteCount: Int
    var fileName: String
}

struct PushAttachmentError: Error, CustomStringConvertible {
    var message: String

    var description: String { message }
}

enum PushAttachmentLoader {
    private static let knownExtensions: [String: String] = [
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/pjpeg": "jpg",
        "image/png": "png",
        "image/gif": "gif",
        "image/heic": "heic",
        "image/heif": "heif",
        "image/webp": "webp",
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/aac": "aac",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/aiff": "aiff",
        "audio/x-aiff": "aiff",
        "video/mp4": "mp4",
        "video/quicktime": "mov",
        "video/x-m4v": "m4v",
        "video/mpeg": "mpg",
        "video/x-msvideo": "avi",
    ]

    static func fileExtension(mimeType: String?, url: URL) -> String {
        if let mimeType {
            let normalized = mimeType
                .split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if let known = knownExtensions[normalized] {
                return known
            }
            if let type = UTType(mimeType: normalized), let preferred = type.preferredFilenameExtension {
                return preferred
            }
        }
        let pathExtension = url.pathExtension.lowercased()
        if !pathExtension.isEmpty {
            return pathExtension == "jpeg" ? "jpg" : pathExtension
        }
        return "jpg"
    }

    static func loadAttachment(from url: URL, identifier: String = "donk-attachment", timeout: TimeInterval = 25) async throws -> PushAttachmentResult {
        let (temporaryURL, mimeType) = try await download(url, timeout: timeout)
        let fileExtension = fileExtension(mimeType: mimeType, url: url)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DonkPush", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let destination = directory.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var options: [AnyHashable: Any] = [:]
        if let type = UTType(filenameExtension: fileExtension) {
            options[UNNotificationAttachmentOptionsTypeHintKey] = type.identifier
        }
        do {
            let attachment = try UNNotificationAttachment(identifier: identifier, url: destination, options: options)
            return PushAttachmentResult(attachment: attachment, sourceURL: url, mimeType: mimeType, byteCount: size, fileName: fileName)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw PushAttachmentError(message: "UNNotificationAttachment rejected .\(fileExtension): \(error.localizedDescription)")
        }
    }

    private static func download(_ url: URL, timeout: TimeInterval) async throws -> (URL, String?) {
        if url.isFileURL {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: copy)
            return (copy, nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        DonkEnvironment.markInternal(configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let request = NSMutableURLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        URLProtocol.setProperty(true, forKey: DonkEnvironment.internalRequestKey, in: request)
        let (location, response) = try await session.download(for: request as URLRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            throw PushAttachmentError(message: "HTTP \(http.statusCode) while downloading \(url.absoluteString)")
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: location, to: kept)
        return (kept, response.mimeType)
    }
}
