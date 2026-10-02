import Foundation

public enum GRPCCallType: String, Codable, Sendable {
    case unary, clientStreaming, serverStreaming, bidirectionalStreaming

    public var label: String {
        switch self {
        case .unary: return "UNARY"
        case .clientStreaming: return "CLIENT STREAM"
        case .serverStreaming: return "SERVER STREAM"
        case .bidirectionalStreaming: return "BIDI STREAM"
        }
    }
}

public struct GRPCMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Direction: String, Codable, Sendable {
        case sent, received
    }

    public var id: UUID
    public var direction: Direction
    public var timestamp: Date
    public var typeName: String
    public var size: Int
    public var json: String?
    public var textFormat: String?
    public var raw: Data?

    public init(
        id: UUID = UUID(),
        direction: Direction,
        timestamp: Date = Date(),
        typeName: String,
        size: Int,
        json: String? = nil,
        textFormat: String? = nil,
        raw: Data? = nil
    ) {
        self.id = id
        self.direction = direction
        self.timestamp = timestamp
        self.typeName = typeName
        self.size = size
        self.json = json
        self.textFormat = textFormat
        self.raw = raw
    }

    public var storedByteCount: Int {
        (json?.utf8.count ?? 0) + (textFormat?.utf8.count ?? 0) + (raw?.count ?? 0)
    }
}

public struct GRPCDetails: Codable, Sendable, Equatable {
    public static let messageLimit = 1000

    public var service: String
    public var method: String
    public var path: String
    public var callType: GRPCCallType
    public var statusCode: Int?
    public var statusMessage: String?
    public var requestMetadata: [HTTPHeader]
    public var responseHeaders: [HTTPHeader]
    public var trailers: [HTTPHeader]
    public var timeout: TimeInterval?
    public private(set) var sentMessageCount: Int
    public private(set) var receivedMessageCount: Int
    public private(set) var sentBytes: Int
    public private(set) var receivedBytes: Int
    public private(set) var storedMessageBytes: Int

    private var messageBuffer: [GRPCMessage]
    private var messageHead: Int

    public init(
        service: String,
        method: String,
        path: String,
        callType: GRPCCallType = .unary,
        statusCode: Int? = nil,
        statusMessage: String? = nil,
        requestMetadata: [HTTPHeader] = [],
        responseHeaders: [HTTPHeader] = [],
        trailers: [HTTPHeader] = [],
        messages: [GRPCMessage] = [],
        timeout: TimeInterval? = nil
    ) {
        self.service = service
        self.method = method
        self.path = path
        self.callType = callType
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.requestMetadata = requestMetadata
        self.responseHeaders = responseHeaders
        self.trailers = trailers
        self.timeout = timeout
        messageBuffer = messages
        messageHead = 0
        storedMessageBytes = Self.storedBytes(of: messages[...])
        let sent = messages.filter { $0.direction == .sent }
        let received = messages.filter { $0.direction == .received }
        sentMessageCount = sent.count
        receivedMessageCount = received.count
        sentBytes = sent.reduce(0) { $0 + $1.size }
        receivedBytes = received.reduce(0) { $0 + $1.size }
    }

    public init(path: String, callType: GRPCCallType, requestMetadata: [HTTPHeader] = [], timeout: TimeInterval? = nil) {
        let parts = Self.split(path: path)
        self.init(
            service: parts.service,
            method: parts.method,
            path: path,
            callType: callType,
            requestMetadata: requestMetadata,
            timeout: timeout
        )
    }

    public var messages: [GRPCMessage] {
        get { messageHead == 0 ? messageBuffer : Array(messageBuffer[messageHead...]) }
        set {
            messageBuffer = newValue
            messageHead = 0
            storedMessageBytes = Self.storedBytes(of: newValue[...])
        }
    }

    public var messageCount: Int {
        messageBuffer.count - messageHead
    }

    public var statusName: String? {
        statusCode.map(Self.statusName(for:))
    }

    public var droppedMessageCount: Int {
        max(0, sentMessageCount + receivedMessageCount - messageCount)
    }

    public mutating func append(_ message: GRPCMessage, limit: Int = GRPCDetails.messageLimit) {
        switch message.direction {
        case .sent:
            sentMessageCount += 1
            sentBytes += message.size
        case .received:
            receivedMessageCount += 1
            receivedBytes += message.size
        }
        messageBuffer.append(message)
        storedMessageBytes += message.storedByteCount
        var overflow = messageCount - max(0, limit)
        while overflow > 0 {
            storedMessageBytes -= messageBuffer[messageHead].storedByteCount
            messageBuffer[messageHead] = Self.evictedPlaceholder
            messageHead += 1
            overflow -= 1
        }
        if messageHead > 64, messageHead * 3 > messageBuffer.count {
            messageBuffer.removeFirst(messageHead)
            messageHead = 0
        }
    }

    // MARK: - Codable & Equatable

    private enum CodingKeys: String, CodingKey {
        case service, method, path, callType, statusCode, statusMessage, requestMetadata, responseHeaders, trailers, messages, timeout
        case sentMessageCount, receivedMessageCount, sentBytes, receivedBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            service: try container.decode(String.self, forKey: .service),
            method: try container.decode(String.self, forKey: .method),
            path: try container.decode(String.self, forKey: .path),
            callType: try container.decode(GRPCCallType.self, forKey: .callType),
            statusCode: try container.decodeIfPresent(Int.self, forKey: .statusCode),
            statusMessage: try container.decodeIfPresent(String.self, forKey: .statusMessage),
            requestMetadata: try container.decodeIfPresent([HTTPHeader].self, forKey: .requestMetadata) ?? [],
            responseHeaders: try container.decodeIfPresent([HTTPHeader].self, forKey: .responseHeaders) ?? [],
            trailers: try container.decodeIfPresent([HTTPHeader].self, forKey: .trailers) ?? [],
            messages: try container.decodeIfPresent([GRPCMessage].self, forKey: .messages) ?? [],
            timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout)
        )
        sentMessageCount = try container.decodeIfPresent(Int.self, forKey: .sentMessageCount) ?? sentMessageCount
        receivedMessageCount = try container.decodeIfPresent(Int.self, forKey: .receivedMessageCount) ?? receivedMessageCount
        sentBytes = try container.decodeIfPresent(Int.self, forKey: .sentBytes) ?? sentBytes
        receivedBytes = try container.decodeIfPresent(Int.self, forKey: .receivedBytes) ?? receivedBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(service, forKey: .service)
        try container.encode(method, forKey: .method)
        try container.encode(path, forKey: .path)
        try container.encode(callType, forKey: .callType)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(requestMetadata, forKey: .requestMetadata)
        try container.encode(responseHeaders, forKey: .responseHeaders)
        try container.encode(trailers, forKey: .trailers)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(timeout, forKey: .timeout)
        try container.encode(sentMessageCount, forKey: .sentMessageCount)
        try container.encode(receivedMessageCount, forKey: .receivedMessageCount)
        try container.encode(sentBytes, forKey: .sentBytes)
        try container.encode(receivedBytes, forKey: .receivedBytes)
    }

    public static func == (lhs: GRPCDetails, rhs: GRPCDetails) -> Bool {
        lhs.service == rhs.service
            && lhs.method == rhs.method
            && lhs.path == rhs.path
            && lhs.callType == rhs.callType
            && lhs.statusCode == rhs.statusCode
            && lhs.statusMessage == rhs.statusMessage
            && lhs.requestMetadata == rhs.requestMetadata
            && lhs.responseHeaders == rhs.responseHeaders
            && lhs.trailers == rhs.trailers
            && lhs.timeout == rhs.timeout
            && lhs.sentMessageCount == rhs.sentMessageCount
            && lhs.receivedMessageCount == rhs.receivedMessageCount
            && lhs.sentBytes == rhs.sentBytes
            && lhs.receivedBytes == rhs.receivedBytes
            && lhs.messageBuffer[lhs.messageHead...].elementsEqual(rhs.messageBuffer[rhs.messageHead...])
    }

    // MARK: - Helpers

    private static let evictedPlaceholder = GRPCMessage(id: UUID(), direction: .sent, timestamp: Date(timeIntervalSince1970: 0), typeName: "", size: 0)

    private static func storedBytes(of messages: ArraySlice<GRPCMessage>) -> Int {
        messages.reduce(0) { $0 + $1.storedByteCount }
    }

    public static func statusName(for code: Int) -> String {
        switch code {
        case 0: return "OK"
        case 1: return "CANCELLED"
        case 2: return "UNKNOWN"
        case 3: return "INVALID_ARGUMENT"
        case 4: return "DEADLINE_EXCEEDED"
        case 5: return "NOT_FOUND"
        case 6: return "ALREADY_EXISTS"
        case 7: return "PERMISSION_DENIED"
        case 8: return "RESOURCE_EXHAUSTED"
        case 9: return "FAILED_PRECONDITION"
        case 10: return "ABORTED"
        case 11: return "OUT_OF_RANGE"
        case 12: return "UNIMPLEMENTED"
        case 13: return "INTERNAL"
        case 14: return "UNAVAILABLE"
        case 15: return "DATA_LOSS"
        case 16: return "UNAUTHENTICATED"
        default: return "CODE \(code)"
        }
    }

    public static func isClientError(_ code: Int) -> Bool {
        [3, 5, 6, 7, 9, 11, 16].contains(code)
    }

    public static func split(path: String) -> (service: String, method: String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last else { return ("", "") }
        guard components.count >= 2 else { return ("", String(last)) }
        return (String(components[components.count - 2]), String(last))
    }
}
