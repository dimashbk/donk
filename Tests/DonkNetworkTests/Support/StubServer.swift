import Foundation
@testable import DonkNetwork

enum StubStep {
    case respond(Int, [String: String])
    case data(Data)
    case text(String)
    case wait(TimeInterval)
    case redirect(Int, String)
    case redirectWithBody(Int, String, String)
    case respondCacheable(Int, [String: String])
    case challenge(String)
    case fail(URLError.Code)
    case finish
}

struct StubRecord {
    let request: URLRequest
    let body: Data
    let date: Date

    var path: String { request.url?.path ?? "" }
    var isHandled: Bool { URLProtocol.property(forKey: DonkURLProtocol.handledKey, in: request) as? Bool == true }
}

final class StubServer: @unchecked Sendable {
    static let shared = StubServer()

    private let lock = NSLock()
    private var routes: [String: (URLRequest, Data) -> [StubStep]] = [:]
    private var records: [StubRecord] = []
    private var stops: [String] = []
    private var outcomes: [String] = []

    func reset() {
        lock.lock()
        routes = [:]
        records = []
        stops = []
        outcomes = []
        lock.unlock()
    }

    func route(_ path: String, _ steps: [StubStep]) {
        route(path) { _, _ in steps }
    }

    func route(_ path: String, _ handler: @escaping (URLRequest, Data) -> [StubStep]) {
        lock.lock()
        routes[path] = handler
        lock.unlock()
    }

    func steps(for request: URLRequest, body: Data) -> [StubStep] {
        let path = request.url?.path ?? ""
        lock.lock()
        let handler = routes[path]
        lock.unlock()
        if let handler { return handler(request, body) }
        return Self.echo(request, body: body)
    }

    func record(_ request: URLRequest, body: Data) {
        lock.lock()
        records.append(StubRecord(request: request, body: body, date: Date()))
        lock.unlock()
    }

    func recordStop(_ path: String) {
        lock.lock()
        stops.append(path)
        lock.unlock()
    }

    func recordOutcome(_ outcome: String) {
        lock.lock()
        outcomes.append(outcome)
        lock.unlock()
    }

    var allRecords: [StubRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func records(path: String) -> [StubRecord] {
        allRecords.filter { $0.path == path }
    }

    var stoppedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    var challengeOutcomes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return outcomes
    }

    static func echo(_ request: URLRequest, body: Data) -> [StubStep] {
        let payload: [String: Any] = [
            "method": request.httpMethod ?? "GET",
            "path": request.url?.path ?? "",
            "query": request.url?.query ?? "",
            "headers": request.allHTTPHeaderFields ?? [:],
            "body": String(decoding: body, as: UTF8.self),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return [
            .respond(200, ["Content-Type": "application/json", "X-Stub": "1", "Content-Length": String(data.count)]),
            .data(data),
            .finish,
        ]
    }
}

final class StubURLProtocol: URLProtocol, URLAuthenticationChallengeSender {
    private static let queue = DispatchQueue(label: "stub.server", attributes: .concurrent)

    private let lock = NSLock()
    private var cancelled = false
    private var channel: ClientChannel?
    private var pendingAfterChallenge: ArraySlice<StubStep>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("donk.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        channel = ClientChannel()
        let body = Self.readBody(of: request)
        StubServer.shared.record(request, body: body)
        let steps = StubServer.shared.steps(for: request, body: body)
        run(steps[...])
    }

    override func stopLoading() {
        lock.lock()
        cancelled = true
        lock.unlock()
        StubServer.shared.recordStop(request.url?.path ?? "")
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func run(_ steps: ArraySlice<StubStep>) {
        guard !isCancelled, let step = steps.first, let client else { return }
        let rest = steps.dropFirst()
        let url = request.url!
        switch step {
        case let .respond(status, headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            run(rest)
        case let .data(data):
            client.urlProtocol(self, didLoad: data)
            run(rest)
        case let .text(text):
            client.urlProtocol(self, didLoad: Data(text.utf8))
            run(rest)
        case let .wait(interval):
            let channel = channel
            Self.queue.asyncAfter(deadline: .now() + interval) { [weak self] in
                channel?.perform { self?.run(rest) }
            }
        case let .redirect(status, location):
            let target = URL(string: location, relativeTo: url)!.absoluteURL
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString, "Content-Length": "0"])!
            var next = URLRequest(url: target)
            next.httpMethod = status == 307 || status == 308 ? request.httpMethod : "GET"
            client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
        case let .redirectWithBody(status, location, text):
            let target = URL(string: location, relativeTo: url)!.absoluteURL
            let body = Data(text.utf8)
            let headers = ["Location": target.absoluteString, "Content-Type": "text/html", "Content-Length": String(body.count)]
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            var next = URLRequest(url: target)
            next.httpMethod = status == 307 || status == 308 ? request.httpMethod : "GET"
            client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        case let .respondCacheable(status, headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            run(rest)
        case let .challenge(method):
            let space = URLProtectionSpace(host: url.host ?? "", port: 443, protocol: "https", realm: "stub", authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: self)
            lock.lock()
            pendingAfterChallenge = rest
            lock.unlock()
            client.urlProtocol(self, didReceive: challenge)
        case let .fail(code):
            client.urlProtocol(self, didFailWithError: URLError(code))
        case .finish:
            client.urlProtocolDidFinishLoading(self)
        }
    }

    private func continueAfterChallenge(_ outcome: String) {
        StubServer.shared.recordOutcome(outcome)
        lock.lock()
        let rest = pendingAfterChallenge
        pendingAfterChallenge = nil
        lock.unlock()
        guard let rest else { return }
        channel?.perform { [weak self] in self?.run(rest) }
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        continueAfterChallenge("use:\(credential.user ?? "trust")")
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        continueAfterChallenge("continue")
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        StubServer.shared.recordOutcome("cancel")
        channel?.perform { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didFailWithError: URLError(.userCancelledAuthentication))
        }
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        continueAfterChallenge("default")
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        continueAfterChallenge("reject")
    }

    static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
