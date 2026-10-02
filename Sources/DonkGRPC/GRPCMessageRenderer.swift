import DonkCore
import Foundation
import SwiftProtobuf

struct GRPCRenderedMessage: Sendable {
    var typeName: String
    var size: Int
    var json: String?
    var textFormat: String?
    var raw: Data?
}

struct GRPCCapture: Sendable {
    let typeName: String
    let size: Int
    let cost: Int
    let render: @Sendable () -> GRPCRenderedMessage
}

struct GRPCEditableBody: Sendable, Equatable {
    var text: String
    var isBinary: Bool

    static let empty = GRPCEditableBody(text: "", isBinary: false)
}

enum GRPCPatchResult<Message> {
    case unchanged
    case patched(Message)
    case invalid
}

struct GRPCDecodingError: Error, CustomStringConvertible {
    var description: String
}

struct GRPCMessageRenderer: Sendable {
    let encoding: JSONEncodingOptions
    let decoding: JSONDecodingOptions
    let maxRenderedSize: Int
    let maxRawSize: Int

    init(options: DonkGRPCOptions) {
        encoding = options.jsonEncodingOptions
        decoding = JSONDecodingOptions()
        maxRenderedSize = max(0, options.maxRenderedMessageSize)
        maxRawSize = max(0, options.maxRawMessageSize)
    }

    // MARK: - Recording

    func capture<Message: SwiftProtobuf.Message>(_ message: Message) -> GRPCCapture {
        let typeName = Message.protoMessageName
        guard let data = try? message.serializedData(partial: true) else {
            return GRPCCapture(typeName: typeName, size: 0, cost: 0) {
                GRPCRenderedMessage(typeName: typeName, size: 0, json: nil, textFormat: message.textFormatString(), raw: nil)
            }
        }
        let size = data.count
        let retained = size <= maxRenderedSize || size <= maxRawSize ? data : nil
        let renderer = self
        return GRPCCapture(typeName: typeName, size: size, cost: retained?.count ?? 0) {
            renderer.render(Message.self, typeName: typeName, size: size, data: retained)
        }
    }

    func skipped(typeName: String, size: Int) -> GRPCRenderedMessage {
        let note = "donk: \(Self.bytes(size)) message, rendering skipped (backlog)"
        return GRPCRenderedMessage(typeName: typeName, size: size, json: nil, textFormat: note, raw: nil)
    }

    private func render<Message: SwiftProtobuf.Message>(
        _ type: Message.Type,
        typeName: String,
        size: Int,
        data: Data?
    ) -> GRPCRenderedMessage {
        let raw = size <= maxRawSize ? data : nil
        guard size <= maxRenderedSize, let data else {
            let note = "donk: \(Self.bytes(size)) message, rendering skipped (limit \(Self.bytes(maxRenderedSize)))"
            return GRPCRenderedMessage(typeName: typeName, size: size, json: nil, textFormat: note, raw: raw)
        }
        guard let message = try? decodeBinary(Message.self, data: data) else {
            let note = "donk: \(Self.bytes(size)) message could not be decoded for rendering"
            return GRPCRenderedMessage(typeName: typeName, size: size, json: nil, textFormat: note, raw: raw)
        }
        if let json = try? message.jsonString(options: encoding) {
            return GRPCRenderedMessage(typeName: typeName, size: size, json: json, textFormat: nil, raw: raw)
        }
        return GRPCRenderedMessage(typeName: typeName, size: size, json: nil, textFormat: message.textFormatString(), raw: raw)
    }

    // MARK: - Editing

    func editable<Message: SwiftProtobuf.Message>(_ message: Message) -> GRPCEditableBody {
        if let json = try? message.jsonString(options: encoding) {
            return GRPCEditableBody(text: JSONFormatting.pretty(json) ?? json, isBinary: false)
        }
        let data = (try? message.serializedData(partial: true)) ?? Data()
        return GRPCEditableBody(text: data.base64EncodedString(), isBinary: true)
    }

    func decodeOne<Message: SwiftProtobuf.Message>(_ type: Message.Type, from body: GRPCEditableBody) throws -> Message {
        if body.isBinary {
            return try decodeBinary(type, base64: body.text)
        }
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return Message() }
        return try Message(jsonString: text, options: decoding)
    }

    func decodeMany<Message: SwiftProtobuf.Message>(_ type: Message.Type, from body: GRPCEditableBody) throws -> [Message] {
        if body.isBinary {
            return try [decodeBinary(type, base64: body.text)]
        }
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        do {
            return try [Message(jsonString: text, options: decoding)]
        } catch {
            guard text.hasPrefix("["), case let .array(items)? = try? JSONValue.parse(text) else { throw error }
            return try items.map { try Message(jsonString: $0.compact(), options: decoding) }
        }
    }

    func decodeJSONList<Message: SwiftProtobuf.Message>(_ type: Message.Type, _ items: [String]) throws -> [Message] {
        try items.map { try Message(jsonString: $0, options: decoding) }
    }

    // MARK: - Rewrite

    func patch<Message: SwiftProtobuf.Message>(_ message: Message, with patch: BodyPatch) -> GRPCPatchResult<Message> {
        switch patch {
        case .keep:
            return .unchanged
        case let .replace(text):
            if text.hasPrefix(Self.base64Prefix) {
                let payload = String(text.dropFirst(Self.base64Prefix.count))
                guard let decoded = try? decodeBinary(Message.self, base64: payload) else { return .invalid }
                return .patched(decoded)
            }
            guard let decoded = try? decodeOne(Message.self, from: GRPCEditableBody(text: text, isBinary: false)) else { return .invalid }
            return .patched(decoded)
        case .findReplace:
            guard let json = try? message.jsonString(options: encoding),
                  let data = patch.apply(to: Data(json.utf8)),
                  let text = String(data: data, encoding: .utf8)
            else { return .unchanged }
            guard text != json else { return .unchanged }
            guard let decoded = try? Message(jsonString: text, options: decoding) else { return .invalid }
            return .patched(decoded)
        }
    }

    // MARK: - Private

    private static let base64Prefix = "base64:"

    private func decodeBinary<Message: SwiftProtobuf.Message>(_ type: Message.Type, base64: String) throws -> Message {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw GRPCDecodingError(description: "invalid base64")
        }
        return try decodeBinary(type, data: data)
    }

    private func decodeBinary<Message: SwiftProtobuf.Message>(_ type: Message.Type, data: Data) throws -> Message {
        var any = Google_Protobuf_Any()
        any.typeURL = "type.googleapis.com/" + Message.protoMessageName
        any.value = data
        return try Message(unpackingAny: any)
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }
}
