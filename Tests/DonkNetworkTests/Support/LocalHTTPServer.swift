import Foundation
import Network

struct LocalHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.http.server")
    private let lock = NSLock()
    private var routes: [String: LocalHTTPResponse] = [:]
    private var hits: [String: Int] = [:]
    private var heads: [String: String] = [:]
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        let ready = AsyncReady()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        await ready.wait()
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func route(_ path: String, _ response: LocalHTTPResponse) {
        lock.lock()
        routes[path] = response
        lock.unlock()
    }

    func lastRequestHead(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return heads[path]
    }

    func hitCount(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hits[path] ?? 0
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]).components(separatedBy: "?")[0] : "/"
        lock.lock()
        hits[path, default: 0] += 1
        heads[path] = head
        let response = routes[path] ?? LocalHTTPResponse(status: 404, headers: [:], body: Data())
        lock.unlock()
        var lines = ["HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))"]
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Date"] = Self.dateFormatter.string(from: Date())
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        var payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}

private final class AsyncReady: @unchecked Sendable {
    private let lock = NSLock()
    private var isReady = false

    func signal() {
        lock.lock()
        isReady = true
        lock.unlock()
    }

    private var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReady
    }

    func wait() async {
        for _ in 0..<500 {
            if ready { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
