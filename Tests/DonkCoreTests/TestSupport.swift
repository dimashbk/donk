import Combine
import Foundation
import XCTest
@testable import DonkCore

func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("donk-core-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        XCTFail("cannot create temp directory: \(error)", file: file, line: line)
    }
    return url
}

func httpEntry(
    id: UUID = UUID(),
    url: String = "https://api.example.com/v1/users?id=42",
    method: String = "GET",
    headers: [HTTPHeader] = [],
    body: BodyData? = nil,
    state: NetworkState = .completed,
    status: Int? = 200,
    responseHeaders: [HTTPHeader] = [],
    responseBody: BodyData? = nil,
    error: NetworkErrorInfo? = nil,
    origin: NetworkOrigin = .network,
    startedAt: Date = Date(),
    duration: TimeInterval? = 0.1,
    isPinned: Bool = false
) -> NetworkEntry {
    NetworkEntry(
        id: id,
        kind: .http,
        state: state,
        origin: origin,
        request: RequestSnapshot(url: url, method: method, headers: headers, body: body),
        response: status.map { ResponseSnapshot(statusCode: $0, headers: responseHeaders, body: responseBody) },
        error: error,
        timing: NetworkTiming(startedAt: startedAt, endedAt: duration.map { startedAt.addingTimeInterval($0) }),
        isPinned: isPinned
    )
}

func grpcEntry(
    path: String = "/bank.v1.AccountService/GetAccount",
    host: String = "api.example.com",
    callType: GRPCCallType = .unary,
    state: NetworkState = .completed,
    statusCode: Int? = 0,
    statusMessage: String? = nil,
    metadata: [HTTPHeader] = [],
    messages: [GRPCMessage] = [],
    error: NetworkErrorInfo? = nil,
    timeout: TimeInterval? = nil
) -> NetworkEntry {
    var details = GRPCDetails(path: path, callType: callType, requestMetadata: metadata, timeout: timeout)
    details.statusCode = statusCode
    details.statusMessage = statusMessage
    for message in messages {
        details.append(message)
    }
    return NetworkEntry(
        kind: .grpc,
        state: state,
        request: RequestSnapshot(url: "grpc://\(host)\(path)", method: "POST", headers: metadata),
        response: statusCode == nil ? nil : ResponseSnapshot(statusCode: 200),
        error: error,
        grpc: details
    )
}

final class EventRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    private var cancellable: AnyCancellable?

    init<P: Publisher>(_ publisher: P) where P.Output == Value, P.Failure == Never {
        cancellable = publisher.sink { [weak self] value in
            guard let self else { return }
            self.lock.lock()
            self.storage.append(value)
            self.lock.unlock()
        }
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
