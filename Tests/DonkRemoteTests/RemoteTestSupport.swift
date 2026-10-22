import DonkCore
import DonkCrash
import Foundation
import XCTest
@testable import DonkRemote

// MARK: - Fixtures

let testSession = UUID(uuidString: "6F1C0000-1111-4222-8333-944455556666")!

let testIdentity = RemoteIdentity(
    session: testSession,
    donkVersion: "0.2.3",
    app: AppInfo(name: "Freedom Business", bundleID: "kz.globerce.fb", version: "1.17.0", build: "1234", osVersion: "26.0", deviceModel: "iPhone17,1"),
    device: RemoteDevice(name: "iPhone 17 Pro", isSimulator: true, simulatorUDID: "39C8B439-0F4B-4F0C-93E3-EC1DE3BB265E")
)

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("donk-remote-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct RemoteFixture {
    var store = NetworkStore()
    var settings: NetworkSettingsStore
    var rules: RuleStore
    var crashes: FakeCrashProvider?
    var ui: RemoteUIProvider?
    var redacts = true
    var redaction: RedactionPolicy?
    var launchDate = Date(timeIntervalSince1970: 1_800_000_000)
    var now = Date(timeIntervalSince1970: 1_800_000_812.4)
    var maxFrameBytes = 16 * 1024 * 1024

    init() {
        let directory = makeTemporaryDirectory()
        settings = NetworkSettingsStore(fileName: "settings.json", directory: directory)
        rules = RuleStore(fileName: "rules.json", directory: directory)
    }

    var context: RemoteContext {
        let now = self.now
        return RemoteContext(
            identity: testIdentity,
            store: store,
            settings: settings,
            rules: rules,
            crashes: crashes,
            ui: ui,
            redacts: redacts,
            redaction: redaction,
            launchDate: launchDate,
            now: { now },
            maxFrameBytes: maxFrameBytes
        )
    }

    var handler: RemoteRequestHandler {
        RemoteRequestHandler(context: context)
    }
}

final class FakeCrashProvider: RemoteCrashProvider, @unchecked Sendable {
    var isInstalled: Bool
    var stored: [CrashReport]

    init(isInstalled: Bool = true, reports: [CrashReport] = []) {
        self.isInstalled = isInstalled
        stored = reports
    }

    func reports() -> [CrashReport] {
        stored
    }

    func text(for report: CrashReport) -> String {
        "TEXT \(report.id.uuidString)"
    }
}

func makeHTTPEntry(
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
    kind: NetworkKind = .http,
    startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000.125),
    duration: TimeInterval? = 0.3412,
    transactions: [TransactionMetrics] = [],
    isPinned: Bool = false
) -> NetworkEntry {
    NetworkEntry(
        id: id,
        kind: kind,
        state: state,
        origin: origin,
        request: RequestSnapshot(url: url, method: method, headers: headers, body: body),
        response: status.map { ResponseSnapshot(statusCode: $0, headers: responseHeaders, body: responseBody) },
        error: error,
        timing: NetworkTiming(startedAt: startedAt, endedAt: duration.map { startedAt.addingTimeInterval($0) }, transactions: transactions),
        web: kind == .webView ? WebViewDetails(pageURL: "https://web.example.com/page?token=abc", initiator: .fetch, captureLevel: .full) : nil,
        isPinned: isPinned
    )
}

func makeGRPCEntry(
    id: UUID = UUID(),
    path: String = "/bank.v1.AccountService/GetAccount",
    host: String = "api.example.com",
    callType: GRPCCallType = .unary,
    state: NetworkState = .completed,
    statusCode: Int? = 0,
    statusMessage: String? = nil,
    metadata: [HTTPHeader] = [],
    messages: [GRPCMessage] = [],
    timeout: TimeInterval? = nil
) -> NetworkEntry {
    var details = GRPCDetails(path: path, callType: callType, requestMetadata: metadata, timeout: timeout)
    details.statusCode = statusCode
    details.statusMessage = statusMessage
    for message in messages {
        details.append(message)
    }
    let sent = messages.first { $0.direction == .sent }?.json
    let received = messages.last { $0.direction == .received }?.json
    return NetworkEntry(
        id: id,
        kind: .grpc,
        state: state,
        request: RequestSnapshot(
            url: "grpc://\(host)\(path)",
            method: "POST",
            headers: metadata,
            body: sent.map { BodyData(text: $0, contentType: "application/json") }
        ),
        response: statusCode == nil ? nil : ResponseSnapshot(statusCode: 200, body: received.map { BodyData(text: $0, contentType: "application/json") }),
        timing: NetworkTiming(startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_000_000.25)),
        grpc: details
    )
}

func sampleCrash(id: UUID = UUID(), date: Date = Date(timeIntervalSince1970: 1_800_000_000), kind: CrashReport.Kind = .exception, reason: String? = "index 3 beyond bounds\n[0 .. 2]") -> CrashReport {
    CrashReport(
        id: id,
        date: date,
        kind: kind,
        appName: "Freedom Business",
        bundleID: "kz.globerce.fb",
        appVersion: "1.17.0",
        appBuild: "1234",
        osVersion: "26.0",
        deviceModel: "iPhone17,1",
        exception: kind == .exception ? CrashReport.ExceptionInfo(name: "NSRangeException", reason: reason, userInfo: [], symbols: []) : nil
    )
}

// MARK: - Calls

struct RemoteCallError: Error, Equatable {
    var code: Int
    var message: String
}

func call(_ handler: RemoteRequestHandler, _ method: String, _ params: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
    let frame = try await rawCall(handler, method, params, file: file, line: line)
    if let error = frame["error"] {
        throw RemoteCallError(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "")
    }
    guard let result = frame["result"] else {
        XCTFail("no result in \(frame.compact())", file: file, line: line)
        return .null
    }
    return result
}

func rawCall(_ handler: RemoteRequestHandler, _ method: String, _ params: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
    var text = #"{"jsonrpc":"2.0","id":"req-1","method":"\#(method)""#
    if let params {
        text += #","params":\#(params)"#
    }
    text += "}"
    guard let response = await handler.handle(text) else {
        XCTFail("no response", file: file, line: line)
        return .null
    }
    let frame = try JSONValue.parse(response)
    XCTAssertEqual(frame["jsonrpc"], .string("2.0"), file: file, line: line)
    XCTAssertEqual(frame["id"], .string("req-1"), file: file, line: line)
    return frame
}

func callError(_ handler: RemoteRequestHandler, _ method: String, _ params: String? = nil, file: StaticString = #filePath, line: UInt = #line) async -> RemoteCallError? {
    do {
        let result = try await call(handler, method, params, file: file, line: line)
        XCTFail("expected an error, got \(result.compact())", file: file, line: line)
        return nil
    } catch let error as RemoteCallError {
        return error
    } catch {
        XCTFail("unexpected \(error)", file: file, line: line)
        return nil
    }
}

// MARK: - JSON access

extension JSONValue {
    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var double: Double? {
        if case let .number(literal) = self { return Double(literal) }
        return nil
    }

    var int: Int? {
        double.map { Int($0) }
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case let .array(values) = self { return values }
        return nil
    }

    var keys: [String] {
        if case let .object(members) = self { return members.map(\.key) }
        return []
    }

    subscript(index: Int) -> JSONValue? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
