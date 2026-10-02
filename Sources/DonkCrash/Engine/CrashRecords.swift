import DonkCore
import Foundation

struct ExceptionRecord: Codable, Equatable, Sendable {
    var name: String
    var reason: String?
    var userInfo: [CrashDetail]
    var addresses: [UInt64]
    var symbols: [String]
    var time: Date
    var threadName: String?
    var isMainThread: Bool
    var images: [RawImage]

    static let userInfoLimit = 64
    static let valueLimit = 4096

    init(
        name: String,
        reason: String?,
        userInfo: [CrashDetail],
        addresses: [UInt64],
        symbols: [String],
        time: Date,
        threadName: String?,
        isMainThread: Bool,
        images: [RawImage]
    ) {
        self.name = name
        self.reason = reason
        self.userInfo = userInfo
        self.addresses = addresses
        self.symbols = symbols
        self.time = time
        self.threadName = threadName
        self.isMainThread = isMainThread
        self.images = images
    }

    init(exception: NSException, images: [RawImage], time: Date = Date()) {
        let info = (exception.userInfo ?? [:])
            .map { CrashDetail("\($0.key)", ExceptionRecord.truncate("\($0.value)")) }
            .sorted { $0.key < $1.key }
        let thread = Thread.current
        let threadName = thread.name.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            name: exception.name.rawValue,
            reason: exception.reason,
            userInfo: Array(info.prefix(ExceptionRecord.userInfoLimit)),
            addresses: exception.callStackReturnAddresses.map { $0.uint64Value },
            symbols: exception.callStackSymbols,
            time: time,
            threadName: threadName,
            isMainThread: Thread.isMainThread,
            images: images
        )
    }

    static func truncate(_ value: String) -> String {
        value.count > valueLimit ? String(value.prefix(valueLimit)) + "…" : value
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> ExceptionRecord? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ExceptionRecord.self, from: data)
    }
}

struct LaunchInfo: Codable, Equatable, Sendable {
    var appName: String
    var bundleID: String
    var version: String
    var build: String
    var osVersion: String
    var deviceModel: String
    var launchDate: Date
    var processID: Int32
    var bundlePath: String

    static func current(date: Date = Date()) -> LaunchInfo {
        let app = DonkEnvironment.appInfo
        return LaunchInfo(
            appName: app.name,
            bundleID: app.bundleID,
            version: app.version,
            build: app.build,
            osVersion: app.osVersion,
            deviceModel: app.deviceModel,
            launchDate: date,
            processID: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundlePath
        )
    }
}

struct SessionMarker: Codable, Equatable, Sendable {
    var version: String
    var build: String
    var osVersion: String
    var launchDate: Date
    var activeDate: Date
    var processID: Int32
    var debuggerAttached: Bool? = nil
}

enum CrashJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? decoder().decode(type, from: data)
    }
}
