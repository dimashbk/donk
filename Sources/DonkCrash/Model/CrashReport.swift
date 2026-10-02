import Foundation

public struct CrashReport: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case signal
        case exception
        case metricKit
        case uncleanExit
    }

    public struct SignalInfo: Codable, Hashable, Sendable {
        public var number: Int32
        public var name: String
        public var code: Int32
        public var codeName: String?
        public var faultAddress: UInt64?
        public var machException: String

        public init(number: Int32, name: String, code: Int32, codeName: String?, faultAddress: UInt64?, machException: String) {
            self.number = number
            self.name = name
            self.code = code
            self.codeName = codeName
            self.faultAddress = faultAddress
            self.machException = machException
        }
    }

    public struct ExceptionInfo: Codable, Hashable, Sendable {
        public var name: String
        public var reason: String?
        public var userInfo: [CrashDetail]
        public var symbols: [String]

        public init(name: String, reason: String?, userInfo: [CrashDetail], symbols: [String]) {
            self.name = name
            self.reason = reason
            self.userInfo = userInfo
            self.symbols = symbols
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var appName: String
    public var bundleID: String
    public var appVersion: String
    public var appBuild: String
    public var osVersion: String
    public var deviceModel: String
    public var architecture: String?
    public var processID: Int32?
    public var launchDate: Date?
    public var signal: SignalInfo?
    public var exception: ExceptionInfo?
    public var crashInfo: [CrashInfoMessage]
    public var threadName: String?
    public var isMainThread: Bool?
    public var frames: [CrashFrame]
    public var signalFrames: [CrashFrame]
    public var registers: [CrashDetail]
    public var binaryImages: [CrashBinaryImage]
    public var loadedImageCount: Int?
    public var details: [CrashDetail]
    public var metricKitTitle: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        kind: Kind,
        appName: String,
        bundleID: String,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        deviceModel: String,
        architecture: String? = nil,
        processID: Int32? = nil,
        launchDate: Date? = nil,
        signal: SignalInfo? = nil,
        exception: ExceptionInfo? = nil,
        crashInfo: [CrashInfoMessage] = [],
        threadName: String? = nil,
        isMainThread: Bool? = nil,
        frames: [CrashFrame] = [],
        signalFrames: [CrashFrame] = [],
        registers: [CrashDetail] = [],
        binaryImages: [CrashBinaryImage] = [],
        loadedImageCount: Int? = nil,
        details: [CrashDetail] = [],
        metricKitTitle: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.appName = appName
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.architecture = architecture
        self.processID = processID
        self.launchDate = launchDate
        self.signal = signal
        self.exception = exception
        self.crashInfo = crashInfo
        self.threadName = threadName
        self.isMainThread = isMainThread
        self.frames = frames
        self.signalFrames = signalFrames
        self.registers = registers
        self.binaryImages = binaryImages
        self.loadedImageCount = loadedImageCount
        self.details = details
        self.metricKitTitle = metricKitTitle
    }
}

public struct CrashFrame: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var address: UInt64
    public var imageName: String?
    public var imageLoadAddress: UInt64?
    public var imageOffset: UInt64?
    public var symbol: String?
    public var symbolOffset: UInt64?
    public var isAppFrame: Bool

    public var id: Int { index }

    public init(
        index: Int,
        address: UInt64,
        imageName: String? = nil,
        imageLoadAddress: UInt64? = nil,
        imageOffset: UInt64? = nil,
        symbol: String? = nil,
        symbolOffset: UInt64? = nil,
        isAppFrame: Bool = false
    ) {
        self.index = index
        self.address = address
        self.imageName = imageName
        self.imageLoadAddress = imageLoadAddress
        self.imageOffset = imageOffset
        self.symbol = symbol
        self.symbolOffset = symbolOffset
        self.isAppFrame = isAppFrame
    }
}

public struct CrashBinaryImage: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var loadAddress: UInt64
    public var size: UInt64
    public var uuid: String?
    public var architecture: String
    public var isApp: Bool
    public var isMainExecutable: Bool

    public var id: String { "\(loadAddress)-\(path)" }

    public init(name: String, path: String, loadAddress: UInt64, size: UInt64, uuid: String?, architecture: String, isApp: Bool, isMainExecutable: Bool) {
        self.name = name
        self.path = path
        self.loadAddress = loadAddress
        self.size = size
        self.uuid = uuid
        self.architecture = architecture
        self.isApp = isApp
        self.isMainExecutable = isMainExecutable
    }
}

public struct CrashInfoMessage: Codable, Hashable, Sendable {
    public var imageName: String?
    public var field: String
    public var text: String

    public init(imageName: String?, field: String, text: String) {
        self.imageName = imageName
        self.field = field
        self.text = text
    }
}

public struct CrashDetail: Codable, Hashable, Sendable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - Presentation

public extension CrashReport {
    var title: String {
        switch kind {
        case .exception:
            return exception?.name ?? "Uncaught exception"
        case .signal:
            if let signal {
                return "\(signal.machException) / \(signal.name)"
            }
            return "Crash"
        case .metricKit:
            return metricKitTitle ?? "MetricKit diagnostic"
        case .uncleanExit:
            return "Unclean exit"
        }
    }

    var subtitle: String? {
        switch kind {
        case .exception:
            if let reason = exception?.reason, !reason.isEmpty {
                return reason
            }
        case .uncleanExit:
            return CrashReport.uncleanExitExplanation
        case .signal, .metricKit:
            break
        }
        if let message = primaryMessage {
            return CrashReport.condensedMessage(message)
        }
        if let frame = topAppFrame, let symbol = frame.symbol {
            return CrashSymbolFormatter.short(symbol)
        }
        if let signal, let codeName = signal.codeName {
            return codeName
        }
        return details.first?.value
    }

    var primaryMessage: String? {
        let texts = crashInfo.filter { ($0.field == "message" || $0.field == "message2") && !CrashReport.isEnvironmentNote($0.text) }
        let swift = texts.first { $0.text.contains("Fatal error") || $0.imageName == "libswiftCore.dylib" }
        let chosen = swift ?? texts.first { !$0.text.hasPrefix("abort() called") } ?? texts.first
        guard let text = chosen?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    var messageEntries: [CrashInfoMessage] {
        crashInfo.filter { $0.field != "backtrace" && !CrashReport.isEnvironmentNote($0.text) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var environmentNotes: [CrashInfoMessage] {
        crashInfo.filter { CrashReport.isEnvironmentNote($0.text) }
    }

    var messageText: String? {
        var lines: [String] = []
        for entry in messageEntries {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lines.contains(text) else { continue }
            lines.append(text)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var topAppFrame: CrashFrame? {
        frames.first { $0.isAppFrame } ?? signalFrames.first { $0.isAppFrame }
    }

    var mainExecutable: CrashBinaryImage? {
        binaryImages.first { $0.isMainExecutable }
    }

    var versionLabel: String {
        appBuild.isEmpty || appBuild == appVersion ? appVersion : "\(appVersion) (\(appBuild))"
    }

    static let uncleanExitExplanation = "Possibly killed by the system (OOM/watchdog) or a debugger"

    static func condensedMessage(_ message: String) -> String {
        guard let range = message.range(of: "Fatal error: ") else { return message }
        let location = message[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        var text = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = "Fatal error"
        }
        guard !location.isEmpty else { return text }
        return "\(text) · \((location as NSString).lastPathComponent)"
    }

    static func isEnvironmentNote(_ text: String) -> Bool {
        if text.hasPrefix("CoreSimulator ") {
            return true
        }
        return text.range(of: #"^dyld\d? config:"#, options: .regularExpression) != nil
    }
}

enum CrashSymbolFormatter {
    static func short(_ symbol: String) -> String {
        var text = symbol
        var prefix = ""
        if text.hasPrefix("closure"), let range = topLevelRange(of: " in ", in: text) {
            prefix = "closure in "
            text = String(text[range.upperBound...])
        }
        for marker in ["static ", "@objc ", "merged ", "dispatch thunk of ", "protocol witness for "] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
        }
        text = text.replacingOccurrences(of: #"\(extension in [^()]+\):"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\(([^()\s]+) in _[0-9A-F]{32}\)"#, with: "$1", options: .regularExpression)
        text = cutReturnType(text)
        if let open = text.firstIndex(of: "(") {
            let name = text[..<open]
            var components = name.split(separator: ".", omittingEmptySubsequences: false)
            if components.count > 2 {
                components.removeFirst()
            }
            text = components.joined(separator: ".") + text[open...]
        }
        text = text.replacingOccurrences(of: "Swift.", with: "")
        return prefix + text
    }

    private static func topLevelRange(of needle: String, in text: String) -> Range<String.Index>? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "(" || character == "<" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" || (character == ">" && !(index > text.startIndex && text[text.index(before: index)] == "-")) {
                depth = max(0, depth - 1)
            } else if depth == 0, text[index...].hasPrefix(needle) {
                return index..<text.index(index, offsetBy: needle.count)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func cutReturnType(_ text: String) -> String {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "(" || character == "<" || character == "[" {
                depth += 1
            } else if character == ")" || character == ">" || character == "]" {
                if !(character == ">" && index > text.startIndex && text[text.index(before: index)] == "-") {
                    depth = max(0, depth - 1)
                }
            } else if depth == 0, text[index...].hasPrefix(" -> ") {
                return String(text[..<index])
            }
            index = text.index(after: index)
        }
        return text
    }
}
