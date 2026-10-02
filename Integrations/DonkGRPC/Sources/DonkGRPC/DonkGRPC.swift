import DonkCore
import Foundation
import GRPC
import SwiftProtobuf

public enum DonkGRPC {
    public static func interceptors<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        host: String?,
        options: DonkGRPCOptions = .init()
    ) -> [ClientInterceptor<Request, Response>] {
        [DonkClientInterceptor<Request, Response>(host: host, options: options)]
    }

    public static func interceptors<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        host: String?,
        options: DonkGRPCOptions = .init(),
        after existing: [ClientInterceptor<Request, Response>]
    ) -> [ClientInterceptor<Request, Response>] {
        existing + interceptors(host: host, options: options)
    }

    public static func register(anyTypes: [any SwiftProtobuf.Message.Type]) {
        AnyTypeRegistry.shared.register(anyTypes)
    }
}

final class AnyTypeRegistry: @unchecked Sendable {
    static let shared = AnyTypeRegistry()

    private let lock = NSLock()
    private var names = Set<String>()

    func register(_ types: [any SwiftProtobuf.Message.Type]) {
        guard !types.isEmpty else { return }
        lock.lock()
        var pending: [any SwiftProtobuf.Message.Type] = []
        for type in types where names.insert(type.protoMessageName).inserted {
            pending.append(type)
        }
        lock.unlock()
        for type in pending {
            Google_Protobuf_Any.register(messageType: type)
        }
    }

    func contains(_ type: any SwiftProtobuf.Message.Type) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return names.contains(type.protoMessageName)
    }
}
