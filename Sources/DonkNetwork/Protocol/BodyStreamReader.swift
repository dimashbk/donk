import DonkCore
import Foundation

package enum RequestBody: Equatable, Sendable {
    case none
    case data(Data)
    case file(URL, size: Int, prefix: Data)

    package var size: Int {
        switch self {
        case .none: return 0
        case let .data(data): return data.count
        case let .file(_, size, _): return size
        }
    }

    package var prefix: Data {
        switch self {
        case .none: return Data()
        case let .data(data): return data
        case let .file(_, _, prefix): return prefix
        }
    }

    package var fileURL: URL? {
        if case let .file(url, _, _) = self { return url }
        return nil
    }

    package func loadData() -> Data {
        switch self {
        case .none: return Data()
        case let .data(data): return data
        case let .file(url, _, prefix): return (try? Data(contentsOf: url)) ?? prefix
        }
    }
}

package enum BodyStreamReader {
    package static let defaultSpillThreshold = 8 * 1024 * 1024

    private static let queue = DispatchQueue(label: "dev.donk.network.body-reader", qos: .userInitiated, attributes: .concurrent)
    private static let chunkSize = 64 * 1024
    private static let cleanup = CleanupState()

    private final class CleanupState: @unchecked Sendable {
        let lock = DonkLock()
        var done = false
    }

    package static func read(
        _ stream: InputStream,
        captureLimit: Int,
        spillThreshold: Int = defaultSpillThreshold,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        completion: @escaping (Result<RequestBody, Error>) -> Void
    ) {
        let box = StreamBox(stream: stream)
        queue.async {
            completion(readSynchronously(box.stream, captureLimit: captureLimit, spillThreshold: spillThreshold, isCancelled: isCancelled))
        }
    }

    package static func removeStaleSpillFilesOnce() {
        let shouldRun: Bool = cleanup.lock.withLock {
            guard !cleanup.done else { return false }
            cleanup.done = true
            return true
        }
        if shouldRun {
            removeSpillFiles()
        }
    }

    package static func removeSpillFiles() {
        let directory = spillDirectory
        queue.async(flags: .barrier) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    package static func readSynchronously(
        _ stream: InputStream,
        captureLimit: Int,
        spillThreshold: Int = defaultSpillThreshold,
        isCancelled: () -> Bool = { false }
    ) -> Result<RequestBody, Error> {
        if stream.streamStatus == .notOpen {
            stream.open()
        }
        defer { stream.close() }
        var memory = Data()
        var prefix = Data()
        var fileURL: URL?
        var handle: FileHandle?
        var total = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let limit = max(0, captureLimit)

        func discardFile() {
            try? handle?.close()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }

        while true {
            if isCancelled() {
                discardFile()
                return .failure(URLError(.cancelled))
            }
            let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return stream.read(base, maxLength: chunkSize)
            }
            if count < 0 {
                discardFile()
                return .failure(stream.streamError ?? URLError(.requestBodyStreamExhausted))
            }
            if count == 0 { break }
            let chunk = Data(buffer[0..<count])
            total += count
            if prefix.count < limit {
                prefix.append(chunk.prefix(limit - prefix.count))
            }
            if let handle {
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    discardFile()
                    return .failure(error)
                }
                continue
            }
            memory.append(chunk)
            if memory.count > spillThreshold {
                do {
                    let url = try makeSpillFile()
                    let created = try FileHandle(forWritingTo: url)
                    fileURL = url
                    handle = created
                    try created.write(contentsOf: memory)
                    memory = Data()
                } catch {
                    discardFile()
                    return .failure(error)
                }
            }
        }
        if let handle, let fileURL {
            do {
                try handle.close()
            } catch {
                discardFile()
                return .failure(error)
            }
            return .success(.file(fileURL, size: total, prefix: prefix))
        }
        return .success(memory.isEmpty ? .none : .data(memory))
    }

    package static var spillDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DonkNetworkUploads", isDirectory: true)
    }

    private static func makeSpillFile() throws -> URL {
        let directory = spillDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}

private struct StreamBox: @unchecked Sendable {
    let stream: InputStream
}
