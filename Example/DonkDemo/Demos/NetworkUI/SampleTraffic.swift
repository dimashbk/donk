import Donk
import Foundation
import UIKit

enum SampleTraffic {
    static let api = "https://api.donkbank.io"
    static let grpcHost = "grpc.donkbank.io:443"
    static var store: NetworkStore { NetworkStore.shared }

    // MARK: - Builders

    static func body(_ text: String, _ type: String = "application/json; charset=utf-8") -> BodyData {
        BodyData(data: Data(text.utf8), contentType: type, limit: store.maxBodySize)
    }

    static func body(_ data: Data, _ type: String) -> BodyData {
        BodyData(data: data, contentType: type, limit: store.maxBodySize)
    }

    static let token = "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c3JfNDIiLCJleHAiOjE3OTU5OTk5OTl9.c2ln"

    static func requestHeaders(_ extra: [HTTPHeader] = [], json: Bool = true) -> [HTTPHeader] {
        var headers = [
            HTTPHeader(name: "Accept", value: json ? "application/json" : "*/*"),
            HTTPHeader(name: "Accept-Encoding", value: "gzip, deflate, br"),
            HTTPHeader(name: "Accept-Language", value: "en-KZ;q=1.0, ru-KZ;q=0.9"),
            HTTPHeader(name: "Authorization", value: token),
            HTTPHeader(name: "User-Agent", value: "DonkDemo/1.0 (iPhone; iOS 26.0) CFNetwork/3826.400 Darwin/25.0.0"),
            HTTPHeader(name: "X-Request-ID", value: UUID().uuidString.lowercased()),
        ]
        headers.append(contentsOf: extra)
        return headers
    }

    static func responseHeaders(type: String?, length: Int, extra: [HTTPHeader] = []) -> [HTTPHeader] {
        var headers: [HTTPHeader] = []
        if let type { headers.append(HTTPHeader(name: "Content-Type", value: type)) }
        headers.append(contentsOf: [
            HTTPHeader(name: "Content-Length", value: "\(length)"),
            HTTPHeader(name: "Date", value: "Wed, 01 Oct 2026 09:41:12 GMT"),
            HTTPHeader(name: "Server", value: "envoy"),
            HTTPHeader(name: "X-Envoy-Upstream-Service-Time", value: "\(Int.random(in: 8...140))"),
            HTTPHeader(name: "Cache-Control", value: "no-store"),
            HTTPHeader(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains"),
        ])
        headers.append(contentsOf: extra)
        return headers
    }

    static func metrics(
        start: Date,
        total: TimeInterval,
        reused: Bool,
        networkProtocol: String = "h2",
        remote: String = "203.0.113.24:443",
        tls: Bool = true,
        requestBytes: Int = 0,
        responseBytes: Int = 0
    ) -> TransactionMetrics {
        var cursor = start
        func step(_ fraction: Double) -> Date {
            cursor = cursor.addingTimeInterval(total * fraction)
            return cursor
        }
        if reused {
            let requestStart = step(0.02)
            let requestEnd = step(0.05)
            let responseStart = step(0.6)
            let responseEnd = step(0.33)
            return TransactionMetrics(
                fetchStart: start, requestStart: requestStart, requestEnd: requestEnd,
                responseStart: responseStart, responseEnd: responseEnd,
                networkProtocol: networkProtocol, remoteAddress: remote,
                tlsProtocol: tls ? "TLS 1.3" : nil, tlsCipherSuite: tls ? "TLS_AES_128_GCM_SHA256" : nil,
                isReusedConnection: true,
                requestHeaderBytes: 412, requestBodyBytes: Int64(requestBytes),
                responseHeaderBytes: 286, responseBodyBytes: Int64(responseBytes)
            )
        }
        let dnsStart = step(0.01)
        let dnsEnd = step(0.09)
        let secureStart = step(tls ? 0.10 : 0.24)
        let secureEnd = step(tls ? 0.14 : 0)
        let requestStart = step(0.01)
        let requestEnd = step(0.04)
        let responseStart = step(0.42)
        let responseEnd = step(0.19)
        return TransactionMetrics(
            fetchStart: start,
            domainLookupStart: dnsStart, domainLookupEnd: dnsEnd,
            connectStart: dnsEnd, connectEnd: secureEnd,
            secureConnectionStart: tls ? secureStart : nil, secureConnectionEnd: tls ? secureEnd : nil,
            requestStart: requestStart, requestEnd: requestEnd,
            responseStart: responseStart, responseEnd: responseEnd,
            networkProtocol: networkProtocol, remoteAddress: remote,
            tlsProtocol: tls ? "TLS 1.3" : nil, tlsCipherSuite: tls ? "TLS_AES_128_GCM_SHA256" : nil,
            isReusedConnection: false,
            requestHeaderBytes: 498, requestBodyBytes: Int64(requestBytes),
            responseHeaderBytes: 312, responseBodyBytes: Int64(responseBytes)
        )
    }

    static func http(
        _ method: String,
        _ url: String,
        status: Int,
        requestBody: BodyData? = nil,
        requestExtra: [HTTPHeader] = [],
        responseBody: BodyData? = nil,
        responseExtra: [HTTPHeader] = [],
        start: Date,
        duration: TimeInterval,
        reused: Bool = true,
        origin: NetworkOrigin = .network,
        pinned: Bool = false
    ) -> NetworkEntry {
        let requestSize = requestBody?.originalSize ?? 0
        let responseSize = responseBody?.originalSize ?? 0
        var extra = requestExtra
        if let type = requestBody?.contentType { extra.insert(HTTPHeader(name: "Content-Type", value: type), at: 0) }
        let transaction = metrics(start: start, total: duration, reused: reused, requestBytes: requestSize, responseBytes: responseSize)
        return NetworkEntry(
            kind: .http,
            state: .completed,
            origin: origin,
            request: RequestSnapshot(url: url, method: method, headers: requestHeaders(extra), body: requestBody),
            response: ResponseSnapshot(
                statusCode: status,
                headers: responseHeaders(type: responseBody?.contentType, length: responseSize, extra: responseExtra),
                body: responseBody
            ),
            timing: NetworkTiming(
                startedAt: start,
                responseStartedAt: transaction.responseStart,
                endedAt: start.addingTimeInterval(duration),
                transactions: [transaction]
            ),
            isPinned: pinned
        )
    }

    static func failed(_ method: String, _ url: String, code: Int, message: String, start: Date, duration: TimeInterval, cancelled: Bool = false) -> NetworkEntry {
        NetworkEntry(
            kind: .http,
            state: cancelled ? .cancelled : .failed,
            request: RequestSnapshot(url: url, method: method, headers: requestHeaders()),
            error: NetworkErrorInfo(domain: NSURLErrorDomain, code: code, message: message),
            timing: NetworkTiming(startedAt: start, endedAt: start.addingTimeInterval(duration))
        )
    }

    // MARK: - Everything

    @MainActor
    static func seedAll() {
        let base = Date().addingTimeInterval(-240)
        seedHTTP(base: base)
        seedWebView(base: base.addingTimeInterval(170))
        startInFlight()
        startEventStream()
        startGRPC()
    }

    // MARK: - HTTP

    @MainActor
    static func seedHTTP(base: Date) {
        var clock = base
        func next(_ seconds: TimeInterval = 4) -> Date {
            clock = clock.addingTimeInterval(seconds)
            return clock
        }
        let largeJSON = SampleBodies.largeTransactions()
        let entries: [NetworkEntry] = [
            redirectEntry(start: next()),
            http("POST", "https://auth.donkbank.io/oauth/token", status: 200,
                 requestBody: body(SampleBodies.formBody, "application/x-www-form-urlencoded"),
                 responseBody: body(SampleBodies.token), start: next(), duration: 0.412, reused: false),
            http("GET", api + "/v1/accounts?include=limits&currency=all", status: 200,
                 responseBody: body(SampleBodies.accounts), responseExtra: [HTTPHeader(name: "ETag", value: "W/\"a91f-3c\"")],
                 start: next(), duration: 0.184, pinned: true),
            http("GET", api + "/v1/profile", status: 401,
                 responseBody: body(SampleBodies.unauthorized),
                 responseExtra: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer error=\"invalid_token\"")],
                 start: next(), duration: 0.096),
            http("PUT", api + "/v1/profile", status: 200,
                 requestBody: body(SampleBodies.profileUpdate), responseBody: body(SampleBodies.profile),
                 start: next(), duration: 0.231),
            http("PATCH", api + "/v1/settings/notifications", status: 200,
                 requestBody: body(#"{"push":true,"marketing":false}"#), responseBody: body(#"{"push":true,"email":false,"sms":true,"marketing":false}"#),
                 start: next(), duration: 0.143),
            http("GET", "https://images.donkbank.io/avatars/usr_42.png?size=320", status: 200,
                 responseBody: body(SampleBodies.avatarPNG(), "image/png"), start: next(), duration: 0.288, reused: false),
            http("POST", api + "/v1/transfers", status: 400,
                 requestBody: body(#"{"fromAccount":"acc_01HV6Q","toPhone":"+7 701","amount":{"value":0,"currency":"KZT"}}"#),
                 responseBody: body(SampleBodies.validationError), start: next(), duration: 0.121),
            http("POST", api + "/v1/transfers", status: 201,
                 requestBody: body(SampleBodies.transferRequest), requestExtra: [HTTPHeader(name: "Idempotency-Key", value: "tr-8c51f0b2")],
                 responseBody: body(SampleBodies.transferResponse),
                 responseExtra: [HTTPHeader(name: "Location", value: "/v1/transfers/tr_01HV9K2M3N")],
                 start: next(), duration: 0.642),
            http("GET", api + "/v1/cards/9999", status: 404, responseBody: body(SampleBodies.notFound), start: next(), duration: 0.088),
            http("HEAD", "https://images.donkbank.io/legacy/logo.png", status: 301,
                 responseExtra: [HTTPHeader(name: "Location", value: "https://images.donkbank.io/brand/logo@3x.png")],
                 start: next(), duration: 0.064),
            http("POST", api + "/v1/payments", status: 500,
                 requestBody: body(#"{"provider":"utilities","account":"4405-1290","amount":{"value":18450,"currency":"KZT"}}"#),
                 responseBody: body(SampleBodies.serverError), start: next(), duration: 1.284),
            http("GET", api + "/v1/rates?base=KZT", status: 503,
                 responseBody: body(SampleBodies.unavailable, "text/plain; charset=utf-8"),
                 responseExtra: [HTTPHeader(name: "Retry-After", value: "30")], start: next(), duration: 2.013),
            http("DELETE", api + "/v1/sessions/current", status: 204, start: next(), duration: 0.077),
            http("GET", api + "/v1/status", status: 200, responseBody: body(SampleBodies.statusText, "text/plain; charset=utf-8"), start: next(), duration: 0.052),
            http("GET", "https://help.donkbank.io/terms", status: 200, responseBody: body(SampleBodies.html, "text/html; charset=utf-8"), start: next(), duration: 0.198, reused: false),
            http("GET", api + "/v1/sync/snapshot.bin", status: 200, responseBody: body(SampleBodies.binary(), "application/octet-stream"), start: next(), duration: 0.344),
            http("GET", api + "/v1/transactions?limit=5200&from=2026-09-01", status: 200,
                 responseBody: body(largeJSON, "application/json"), start: next(), duration: 1.873),
            http("GET", api + "/v1/logs/export?format=text", status: 200,
                 responseBody: body(SampleBodies.largeLog(), "text/plain; charset=utf-8"), start: next(), duration: 3.420),
            failed("GET", api + "/v1/reports/annual?year=2025", code: NSURLErrorTimedOut, message: "The request timed out.", start: next(), duration: 30.0),
            failed("GET", "https://api.donkbank-staging.internal/health", code: NSURLErrorCannotFindHost, message: "A server with the specified hostname could not be found.", start: next(), duration: 0.018),
            failed("GET", api + "/v1/search?q=coff", code: NSURLErrorCancelled, message: "cancelled", start: next(), duration: 0.142, cancelled: true),
            http("GET", api + "/v1/balance", status: 200, responseBody: body(SampleBodies.balance),
                 start: next(), duration: 0.502, origin: .mocked(rule: "Mock balance")),
            http("GET", api + "/v1/feature-flags?platform=ios", status: 200, responseBody: body(SampleBodies.featureFlags),
                 start: next(), duration: 0.133, origin: .rewritten(rule: "Enable new onboarding")),
            http("POST", "https://auth.donkbank.io/v1/login", status: 200,
                 requestBody: body(#"{"phone":"+77015550182","otp":"000000"}"#), responseBody: body(SampleBodies.token),
                 start: next(), duration: 4.818, origin: .breakpoint(edited: true)),
            http("POST", "https://events.metrics-hub.io/v2/batch", status: 202,
                 requestBody: body(#"{"events":[{"name":"screen_view","screen":"home"},{"name":"tap","target":"transfer"}]}"#),
                 start: next(), duration: 0.091, reused: false),
        ]
        for entry in entries {
            store.add(entry)
        }
    }

    static func redirectEntry(start: Date) -> NetworkEntry {
        let config = #"{"minVersion":"1.0.0","maintenance":false,"supportPhone":"+7 727 000 00 00"}"#
        let first = metrics(start: start, total: 0.118, reused: false, networkProtocol: "http/1.1", remote: "203.0.113.24:80", tls: false)
        let second = metrics(start: start.addingTimeInterval(0.122), total: 0.214, reused: false, requestBytes: 0, responseBytes: config.utf8.count)
        return NetworkEntry(
            kind: .http,
            state: .completed,
            request: RequestSnapshot(url: "http://api.donkbank.io/v1/app/config", method: "GET", headers: requestHeaders()),
            response: ResponseSnapshot(statusCode: 200, headers: responseHeaders(type: "application/json", length: config.utf8.count), body: body(config)),
            timing: NetworkTiming(startedAt: start, responseStartedAt: second.responseStart, endedAt: start.addingTimeInterval(0.336), transactions: [first, second])
        )
    }

    // MARK: - WebView

    static func seedWebView(base: Date) {
        let page = "https://help.donkbank.io/articles/limits"
        let webViewID = "WKWebView-0x6000037a8000"
        let document = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(url: page, method: "GET", headers: [HTTPHeader(name: "Accept", value: "text/html")]),
            response: ResponseSnapshot(statusCode: 200, headers: [
                HTTPHeader(name: "Content-Type", value: "text/html; charset=utf-8"),
                HTTPHeader(name: "Cache-Control", value: "max-age=600"),
            ]),
            timing: NetworkTiming(startedAt: base, responseStartedAt: base.addingTimeInterval(0.21), endedAt: base.addingTimeInterval(0.38)),
            web: WebViewDetails(pageURL: page, initiator: .document, captureLevel: .metadata, webViewID: webViewID)
        )
        let script = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(url: "https://help.donkbank.io/static/app.4f9c2e.js", method: "GET"),
            timing: NetworkTiming(startedAt: base.addingTimeInterval(0.41), endedAt: base.addingTimeInterval(0.53)),
            web: WebViewDetails(pageURL: page, initiator: .resource, captureLevel: .observed, webViewID: webViewID)
        )
        let image = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(url: "https://help.donkbank.io/static/hero-limits.webp", method: "GET"),
            timing: NetworkTiming(startedAt: base.addingTimeInterval(0.44), endedAt: base.addingTimeInterval(0.71)),
            web: WebViewDetails(pageURL: page, initiator: .resource, captureLevel: .observed, webViewID: webViewID)
        )
        let related = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(url: "https://help.donkbank.io/api/articles/related?id=42", method: "GET", headers: [HTTPHeader(name: "Accept", value: "application/json")]),
            response: ResponseSnapshot(statusCode: 200, headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: body(#"{"articles":[{"id":43,"title":"Raise your limits"},{"id":51,"title":"Card controls"}]}"#)),
            timing: NetworkTiming(startedAt: base.addingTimeInterval(0.8), responseStartedAt: base.addingTimeInterval(0.9), endedAt: base.addingTimeInterval(0.95)),
            web: WebViewDetails(pageURL: page, initiator: .xhr, captureLevel: .full, webViewID: webViewID)
        )
        let chat = NetworkEntry(
            kind: .webView,
            state: .completed,
            request: RequestSnapshot(
                url: "https://help.donkbank.io/api/chat/messages",
                method: "POST",
                headers: [HTTPHeader(name: "Content-Type", value: "application/json"), HTTPHeader(name: "X-CSRF-Token", value: "c8f1e2a9")],
                body: body(SampleBodies.chatRequest)
            ),
            response: ResponseSnapshot(statusCode: 200, headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: body(SampleBodies.chatResponse)),
            timing: NetworkTiming(startedAt: base.addingTimeInterval(2.1), responseStartedAt: base.addingTimeInterval(2.7), endedAt: base.addingTimeInterval(2.76)),
            web: WebViewDetails(pageURL: page, initiator: .fetch, captureLevel: .full, webViewID: webViewID)
        )
        for entry in [document, script, image, related, chat] {
            store.add(entry)
        }
    }

    // MARK: - In flight

    @MainActor
    static func startInFlight() {
        schedule("POST", api + "/v1/payments/confirm", requestBody: body(#"{"paymentId":"pay_7781","otp":"482913"}"#), after: 3,
                 status: 200, responseBody: body(#"{"paymentId":"pay_7781","status":"completed","balanceAfter":1259500.75}"#))
        schedule("GET", api + "/v1/statements/export?month=2026-09", requestBody: nil, after: 5.5,
                 status: 200, responseBody: body(SampleBodies.accounts))
        schedule("GET", api + "/v1/notifications/poll?cursor=n_1827", requestBody: nil, after: 9,
                 status: 200, responseBody: body(#"{"notifications":[{"id":"n_1828","title":"Payment received","body":"+25 000 ₸ from Aruzhan"}],"cursor":"n_1828"}"#))
    }

    static func schedule(_ method: String, _ url: String, requestBody: BodyData?, after delay: TimeInterval, status: Int, responseBody: BodyData) {
        let start = Date()
        var headers: [HTTPHeader] = []
        if let type = requestBody?.contentType { headers.append(HTTPHeader(name: "Content-Type", value: type)) }
        let entry = NetworkEntry(
            kind: .http,
            state: .pending,
            request: RequestSnapshot(url: url, method: method, headers: requestHeaders(headers), body: requestBody),
            timing: NetworkTiming(startedAt: start)
        )
        let id = entry.id
        store.add(entry)
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let end = Date()
            let transaction = metrics(start: start, total: end.timeIntervalSince(start), reused: true, requestBytes: requestBody?.originalSize ?? 0, responseBytes: responseBody.originalSize)
            store.update(id) { entry in
                entry.state = .completed
                entry.response = ResponseSnapshot(statusCode: status, headers: responseHeaders(type: responseBody.contentType, length: responseBody.originalSize), body: responseBody)
                entry.timing.responseStartedAt = transaction.responseStart
                entry.timing.endedAt = end
                entry.timing.transactions = [transaction]
            }
        }
    }

    // MARK: - Server-sent events

    static func startEventStream() {
        let start = Date()
        let entry = NetworkEntry(
            kind: .http,
            state: .pending,
            request: RequestSnapshot(
                url: api + "/v1/quotes/stream?symbols=USD,EUR,GBP",
                method: "GET",
                headers: requestHeaders([HTTPHeader(name: "Accept", value: "text/event-stream"), HTTPHeader(name: "Cache-Control", value: "no-cache")])
            ),
            timing: NetworkTiming(startedAt: start)
        )
        let id = entry.id
        store.add(entry)
        Task.detached {
            try? await Task.sleep(nanoseconds: 350_000_000)
            store.update(id) { entry in
                entry.state = .streaming
                entry.timing.responseStartedAt = Date()
                entry.response = ResponseSnapshot(statusCode: 200, headers: [
                    HTTPHeader(name: "Content-Type", value: "text/event-stream; charset=utf-8"),
                    HTTPHeader(name: "Cache-Control", value: "no-cache"),
                    HTTPHeader(name: "Connection", value: "keep-alive"),
                    HTTPHeader(name: "X-Accel-Buffering", value: "no"),
                ])
            }
            var text = "retry: 3000\n\n"
            let symbols = ["USD", "EUR", "GBP"]
            for index in 1...60 {
                try? await Task.sleep(nanoseconds: 650_000_000)
                let symbol = symbols[index % symbols.count]
                let bid = 478.5 + Double(index % 9) * 0.37
                text += "id: \(index)\nevent: quote\ndata: {\"symbol\":\"\(symbol)\",\"bid\":\(String(format: "%.2f", bid)),\"ask\":\(String(format: "%.2f", bid + 3.6)),\"seq\":\(index)}\n\n"
                if index % 12 == 0 { text += ": keep-alive\n\n" }
                let snapshot = BodyData(data: Data(text.utf8), contentType: "text/event-stream; charset=utf-8", limit: store.maxBodySize)
                store.update(id) { $0.response?.body = snapshot }
            }
            store.update(id) { entry in
                entry.state = .completed
                entry.timing.endedAt = Date()
            }
        }
    }

    // MARK: - gRPC

    static let grpcMetadata = [
        HTTPHeader(name: "content-type", value: "application/grpc"),
        HTTPHeader(name: "te", value: "trailers"),
        HTTPHeader(name: "user-agent", value: "grpc-swift-nio/1.23.0"),
        HTTPHeader(name: "authorization", value: token),
        HTTPHeader(name: "x-device-id", value: "8C1F2A40-7E1D-4B9A-9F33-2D6A0C51B7E2"),
        HTTPHeader(name: "x-app-version", value: "1.0 (42)"),
    ]

    static let grpcResponseHeaders = [
        HTTPHeader(name: "content-type", value: "application/grpc+proto"),
        HTTPHeader(name: "grpc-encoding", value: "identity"),
        HTTPHeader(name: "server", value: "envoy"),
        HTTPHeader(name: "date", value: "Wed, 01 Oct 2026 09:41:14 GMT"),
    ]

    static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func startGRPC() {
        Task.detached {
            await grpcUnaryOK()
            await sleep(0.4)
            await grpcUnaryUnavailable()
            await sleep(0.3)
            await grpcTransportFailure()
        }
        Task.detached { await grpcServerStream() }
        Task.detached {
            await sleep(1.0)
            await grpcBidi()
        }
        Task.detached {
            await sleep(0.6)
            await grpcClientStream()
        }
    }

    static func grpcUnaryOK() async {
        let recorder = GRPCCallRecorder(host: grpcHost, path: "/bank.v1.AccountService/GetAccount", callType: .unary, requestMetadata: grpcMetadata, timeout: 10)
        recorder.didSend(typeName: "bank.v1.GetAccountRequest", size: 18, json: #"{"accountId":"acc_01HV6Q","includeLimits":true}"#, textFormat: "account_id: \"acc_01HV6Q\"\ninclude_limits: true")
        await sleep(0.14)
        recorder.didReceiveHeaders(grpcResponseHeaders)
        recorder.didReceive(
            typeName: "bank.v1.Account",
            size: 214,
            json: #"{"id":"acc_01HV6Q","type":"ACCOUNT_TYPE_CURRENT","currency":"KZT","balance":{"units":"1284500","nanos":750000000},"limits":{"daily":{"units":"2000000"},"monthly":{"units":"15000000"}},"primary":true}"#,
            textFormat: "id: \"acc_01HV6Q\"\ntype: ACCOUNT_TYPE_CURRENT\ncurrency: \"KZT\"\nbalance {\n  units: 1284500\n  nanos: 750000000\n}\nprimary: true",
            raw: Data([0x0A, 0x0A, 0x61, 0x63, 0x63, 0x5F, 0x30, 0x31, 0x48, 0x56, 0x36, 0x51, 0x10, 0x01, 0x1A, 0x03, 0x4B, 0x5A, 0x54])
        )
        await sleep(0.02)
        recorder.didFinish(statusCode: 0, message: nil, trailers: [
            HTTPHeader(name: "grpc-status", value: "0"),
            HTTPHeader(name: "x-request-id", value: "c41f7a2e-0b1d-4a77-9a10-77e5c2d0b8f3"),
        ])
    }

    static func grpcUnaryUnavailable() async {
        let recorder = GRPCCallRecorder(host: grpcHost, path: "/bank.v1.PaymentService/CreatePayment", callType: .unary, requestMetadata: grpcMetadata, timeout: 15)
        recorder.didSend(typeName: "bank.v1.CreatePaymentRequest", size: 96, json: #"{"provider":"utilities","account":"4405-1290","amount":{"units":"18450","currencyCode":"KZT"},"idempotencyKey":"pay-55c1"}"#)
        await sleep(1.2)
        recorder.didFinish(statusCode: 14, message: SampleBodies.unavailable, trailers: [
            HTTPHeader(name: "grpc-status", value: "14"),
            HTTPHeader(name: "grpc-message", value: "upstream connect error or disconnect/reset before headers"),
            HTTPHeader(name: "x-envoy-overloaded", value: "true"),
            HTTPHeader(name: "grpc-retry-pushback-ms", value: "1500"),
        ])
    }

    static func grpcTransportFailure() async {
        let recorder = GRPCCallRecorder(host: grpcHost, path: "/bank.v1.CardService/ListCards", callType: .unary, requestMetadata: grpcMetadata, timeout: 5)
        recorder.didSend(typeName: "bank.v1.ListCardsRequest", size: 4, json: #"{"pageSize":20}"#)
        await sleep(0.8)
        recorder.didFail(NSError(domain: "GRPC.GRPCConnectionPoolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Deadline exceeded while waiting for a connection to become available"]))
    }

    static func grpcServerStream() async {
        let recorder = GRPCCallRecorder(host: grpcHost, path: "/market.v1.QuotesService/StreamQuotes", callType: .serverStreaming, requestMetadata: grpcMetadata, timeout: nil)
        recorder.didSend(typeName: "market.v1.StreamQuotesRequest", size: 22, json: #"{"symbols":["USD/KZT","EUR/KZT","BTC/USD"],"depth":1}"#)
        await sleep(0.2)
        recorder.didReceiveHeaders(grpcResponseHeaders)
        let symbols = ["USD/KZT", "EUR/KZT", "BTC/USD"]
        for index in 0..<120 {
            await sleep(0.22)
            let symbol = symbols[index % symbols.count]
            let price = symbol == "BTC/USD" ? 64_210.5 + Double(index) * 3.25 : 478.5 + Double(index % 13) * 0.11
            recorder.didReceive(
                typeName: "market.v1.Quote",
                size: 46 + index % 7,
                json: "{\"symbol\":\"\(symbol)\",\"price\":\(String(format: "%.2f", price)),\"change\":\(String(format: "%.3f", Double(index % 11 - 5) / 100)),\"sequence\":\(index + 1)}",
                textFormat: "symbol: \"\(symbol)\"\nprice: \(String(format: "%.2f", price))\nsequence: \(index + 1)"
            )
        }
        recorder.didFinish(statusCode: 0, message: nil, trailers: [HTTPHeader(name: "grpc-status", value: "0")])
    }

    static func grpcBidi() async {
        let recorder = GRPCCallRecorder(host: grpcHost, path: "/support.v1.ChatService/Converse", callType: .bidirectionalStreaming, requestMetadata: grpcMetadata, timeout: nil)
        let lines: [(Bool, String)] = [
            (true, "Hi! My card payment was declined."),
            (false, "Sorry to hear that. Which card are you using?"),
            (true, "The one ending in 1290."),
            (false, "Thanks. I can see an online limit of 50 000 ₸ on it."),
            (false, "Your payment was 62 300 ₸, so it went over the limit."),
            (true, "Can you raise it to 100 000?"),
            (false, "Done — the new limit is active right away."),
            (true, "Great, thank you!"),
        ]
        await sleep(0.1)
        recorder.didReceiveHeaders(grpcResponseHeaders)
        for (index, line) in lines.enumerated() {
            await sleep(line.0 ? 1.1 : 0.7)
            let json = "{\"conversationId\":\"conv_77\",\"seq\":\(index + 1),\"text\":\"\(line.1)\"}"
            if line.0 {
                recorder.didSend(typeName: "support.v1.ClientMessage", size: line.1.utf8.count + 24, json: json)
            } else {
                recorder.didReceive(typeName: "support.v1.AgentMessage", size: line.1.utf8.count + 30, json: json)
            }
        }
        await sleep(0.4)
        recorder.didFinish(statusCode: 0, message: nil, trailers: [HTTPHeader(name: "grpc-status", value: "0")])
    }

    static func grpcClientStream() async {
        let recorder = GRPCCallRecorder(host: grpcHost, path: "/docs.v1.DocumentService/UploadChunks", callType: .clientStreaming, requestMetadata: grpcMetadata, timeout: 60)
        for index in 0..<12 {
            await sleep(0.15)
            recorder.didSend(typeName: "docs.v1.Chunk", size: 65_536, json: "{\"documentId\":\"doc_passport\",\"index\":\(index),\"bytes\":65536,\"sha256\":\"\(String(format: "%08x", index * 2_654_435_761 % 4_294_967_291))…\"}")
        }
        await sleep(0.3)
        recorder.didReceiveHeaders(grpcResponseHeaders)
        recorder.didReceive(typeName: "docs.v1.UploadSummary", size: 64, json: #"{"documentId":"doc_passport","chunks":12,"bytes":786432,"status":"STORED"}"#)
        recorder.didFinish(statusCode: 0, message: nil, trailers: [HTTPHeader(name: "grpc-status", value: "0")])
    }

    // MARK: - Rules

    static func installRules() {
        func id(_ suffix: Int) -> UUID {
            UUID(uuidString: String(format: "D0C0FFEE-0000-4000-8000-%012d", suffix)) ?? UUID()
        }
        let rules = [
            NetworkRule(
                id: id(1),
                name: "Mock balance",
                match: RuleMatch(kinds: [.http], method: "GET", url: URLMatcher(pattern: "api.donkbank.io/v1/balance", mode: .contains)),
                action: .mapLocal(MockResponse(statusCode: 200, headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: JSONFormatting.pretty(SampleBodies.balance) ?? SampleBodies.balance, delay: 0.5))
            ),
            NetworkRule(
                id: id(2),
                name: "Enable new onboarding",
                match: RuleMatch(kinds: [.http], url: URLMatcher(pattern: "https://api.donkbank.io/v1/feature-flags*", mode: .wildcard)),
                action: .rewrite(request: nil, response: ResponseRewrite(body: .findReplace([FindReplace(find: "\"newOnboarding\":false", replace: "\"newOnboarding\":true")])))
            ),
            NetworkRule(
                id: id(3),
                name: "Pause transfers",
                match: RuleMatch(kinds: [.http], method: "POST", url: URLMatcher(pattern: "/v1/transfers$", mode: .regex)),
                action: .breakpoint(request: true, response: false)
            ),
            NetworkRule(
                id: id(4),
                name: "Rates outage",
                isEnabled: false,
                match: RuleMatch(kinds: [.http], url: URLMatcher(pattern: "/v1/rates", mode: .contains)),
                action: .rewrite(request: RequestRewrite(headers: HeaderPatch(set: [HTTPHeader(name: "X-Debug-Fault", value: "503")])), response: ResponseRewrite(statusCode: 503))
            ),
            NetworkRule(
                id: id(5),
                name: "Payments unavailable (gRPC)",
                isEnabled: false,
                match: RuleMatch(kinds: [.grpc], url: URLMatcher(pattern: "PaymentService/CreatePayment", mode: .contains)),
                action: .mapLocal(MockResponse(grpcStatusCode: 14, grpcStatusMessage: "maintenance window", grpcMessages: []))
            ),
        ]
        for rule in rules {
            RuleStore.shared.add(rule)
        }
    }

    // MARK: - Breakpoints

    static func triggerRequestBreakpoint() {
        let request = RequestSnapshot(
            url: api + "/v1/transfers",
            method: "POST",
            headers: requestHeaders([HTTPHeader(name: "Content-Type", value: "application/json"), HTTPHeader(name: "Idempotency-Key", value: "tr-\(Int.random(in: 1000...9999))")]),
            body: body(SampleBodies.transferRequest)
        )
        let entry = NetworkEntry(kind: .http, state: .paused, request: request, timing: NetworkTiming(startedAt: Date()))
        let id = entry.id
        store.add(entry)
        Task.detached {
            let original = EditableRequest(snapshot: request)
            let exchange = PausedExchange(entryID: id, kind: .http, phase: .request, ruleName: "Pause transfers", payload: .request(original))
            let decision = await BreakpointCenter.shared.pause(exchange)
            switch decision {
            case let .resume(.request(edited)):
                let changed = edited != original
                let editedBody = body(edited.bodyData, "application/json")
                store.update(id) { entry in
                    entry.state = .pending
                    entry.origin = .breakpoint(edited: changed)
                    if changed {
                        entry.request.url = edited.url
                        entry.request.method = edited.method
                        entry.request.headers = edited.headers
                        entry.request.body = editedBody
                    }
                }
                await sleep(0.45)
                let response = body(SampleBodies.transferResponse)
                store.update(id) { entry in
                    entry.state = .completed
                    entry.response = ResponseSnapshot(statusCode: 201, headers: responseHeaders(type: response.contentType, length: response.originalSize), body: response)
                    entry.timing.responseStartedAt = Date()
                    entry.timing.endedAt = Date()
                }
            case let .respond(local):
                let localBody = body(local.bodyData, local.headers.value(for: "Content-Type") ?? "application/json")
                store.update(id) { entry in
                    entry.state = .completed
                    entry.origin = .breakpoint(edited: true)
                    entry.response = ResponseSnapshot(statusCode: local.statusCode, headers: local.headers, body: localBody)
                    entry.timing.responseStartedAt = Date()
                    entry.timing.endedAt = Date()
                }
            case .resume(.response):
                break
            case .abort:
                store.update(id) { entry in
                    entry.state = .cancelled
                    entry.error = NetworkErrorInfo(domain: NSURLErrorDomain, code: NSURLErrorCancelled, message: "Aborted at breakpoint")
                    entry.timing.endedAt = Date()
                }
            }
        }
    }

    static func triggerGRPCResponseBreakpoint() {
        Task.detached {
            let recorder = GRPCCallRecorder(host: grpcHost, path: "/limits.v1.LimitsService/GetLimits", callType: .unary, requestMetadata: grpcMetadata, timeout: 30)
            recorder.didSend(typeName: "limits.v1.GetLimitsRequest", size: 12, json: #"{"cardId":"card_1290"}"#)
            await sleep(0.2)
            recorder.didReceiveHeaders(grpcResponseHeaders)
            let id = recorder.entryID
            store.update(id) { $0.state = .paused }
            let json = #"{"cardId":"card_1290","online":{"units":"50000"},"atm":{"units":"200000"},"contactless":{"units":"30000"}}"#
            let original = EditableResponse(statusCode: 200, headers: grpcResponseHeaders, body: json, grpcStatusCode: 0)
            let exchange = PausedExchange(entryID: id, kind: .grpc, phase: .response, ruleName: "Inspect limits", payload: .response(original))
            let decision = await BreakpointCenter.shared.pause(exchange)
            store.update(id) { $0.state = .pending }
            switch decision {
            case let .resume(.response(edited)):
                if edited != original { recorder.setOrigin(.breakpoint(edited: true)) }
                recorder.didReceive(typeName: "limits.v1.Limits", size: edited.body.utf8.count, json: edited.body)
                recorder.didFinish(statusCode: edited.grpcStatusCode ?? 0, message: edited.grpcStatusMessage, trailers: [HTTPHeader(name: "grpc-status", value: "\(edited.grpcStatusCode ?? 0)")])
            case let .respond(local):
                recorder.setOrigin(.breakpoint(edited: true))
                recorder.didReceive(typeName: "limits.v1.Limits", size: local.body.utf8.count, json: local.body)
                recorder.didFinish(statusCode: local.grpcStatusCode ?? 0, message: local.grpcStatusMessage, trailers: [])
            case .resume(.request):
                recorder.didFinish(statusCode: 0, message: nil, trailers: [])
            case .abort:
                recorder.didFinish(statusCode: 1, message: "Aborted at breakpoint", trailers: [])
            }
        }
    }

    // MARK: - Trickle

    static func startTrickle(count: Int = 40, interval: TimeInterval = 1.5) {
        Task.detached(priority: .utility) {
            let paths = ["/v1/accounts", "/v1/notifications/unread", "/v1/rates?base=KZT", "/v1/cards", "/v1/offers/home", "/v1/profile/limits"]
            for index in 0..<count {
                await sleep(interval)
                let path = paths[index % paths.count]
                let json = "{\"tick\":\(index),\"ok\":true}"
                await MainActor.run {
                    schedule("GET", api + path, requestBody: nil, after: 0.25 + Double(index % 4) * 0.2, status: index % 9 == 8 ? 500 : 200, responseBody: body(json))
                }
            }
        }
    }

    // MARK: - Bulk

    static func addBulk(count: Int) {
        Task.detached(priority: .utility) {
            var generator = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970))
            let hosts = ["api.donkbank.io", "auth.donkbank.io", "images.donkbank.io", "events.metrics-hub.io", "cdn.donkbank.io", "help.donkbank.io"]
            let paths = ["/v1/accounts", "/v1/transactions", "/v1/cards/1290", "/v1/profile", "/v1/rates", "/v2/batch", "/v1/notifications", "/static/app.js", "/avatars/usr_42.png", "/v1/transfers"]
            let methods = ["GET", "GET", "GET", "POST", "PUT", "PATCH", "DELETE"]
            let statuses = [200, 200, 200, 200, 201, 204, 304, 400, 401, 404, 500, 503]
            let start = Date().addingTimeInterval(-Double(count) * 0.05)
            for index in 0..<count {
                let host = hosts[Int.random(in: 0..<hosts.count, using: &generator)]
                let path = paths[Int.random(in: 0..<paths.count, using: &generator)]
                let method = methods[Int.random(in: 0..<methods.count, using: &generator)]
                let status = statuses[Int.random(in: 0..<statuses.count, using: &generator)]
                let begin = start.addingTimeInterval(Double(index) * 0.05)
                let duration = Double.random(in: 0.03...1.6, using: &generator)
                let json = "{\"index\":\(index),\"ok\":\(status < 400),\"items\":[\(index % 7),\(index % 11)]}"
                let entry = http(
                    method,
                    "https://\(host)\(path)?page=\(index % 40)",
                    status: status,
                    requestBody: method == "GET" || method == "DELETE" ? nil : body(#"{"value":\#(index)}"#),
                    responseBody: status == 204 || status == 304 ? nil : body(json),
                    start: begin,
                    duration: duration,
                    reused: index % 5 != 0
                )
                store.add(entry)
            }
        }
    }
}
