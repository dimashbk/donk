import Donk
import Foundation

enum DemoLaunchOptions {
    @MainActor
    static func apply(_ defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: "DonkClearRules") {
            RuleStore.shared.removeAll()
        }
        if defaults.object(forKey: "DonkRedactExports") != nil {
            let redacts = defaults.bool(forKey: "DonkRedactExports")
            NetworkSettingsStore.shared.update { $0.redactsExports = redacts }
        }
        if defaults.bool(forKey: "DonkSeedRules") {
            DemoSampleData.seedRules()
        }
        if defaults.bool(forKey: "DonkSeedTraffic") {
            DemoSampleData.seedTraffic()
        }
        if let target = defaults.string(forKey: "DonkOpen") {
            open(target)
        }
        if defaults.bool(forKey: "DonkSeedBreakpoint") {
            let resolveAfter = defaults.double(forKey: "DonkResolveBreakpointAfter")
            DemoSampleData.pauseSampleRequest(after: 1.5, resolveAfter: resolveAfter > 0 ? resolveAfter : nil)
        }
    }

    @MainActor
    static func open(_ target: String) {
        let value = target.trimmingCharacters(in: .whitespaces)
        switch value.lowercased() {
        case "", "home":
            Donk.show()
        case "quickactions", "quick-actions", "menu":
            Donk.showQuickActions()
        default:
            if let tool = DonkTool.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) {
                Donk.show(tool)
            } else {
                Donk.show()
            }
        }
    }
}

enum DemoSampleData {
    private static let ruleIDs = [
        UUID(uuidString: "6D5DFC00-0000-4000-8000-000000000001")!,
        UUID(uuidString: "6D5DFC00-0000-4000-8000-000000000002")!,
    ]

    static func seedRules() {
        let existing = Set(RuleStore.shared.rules.map(\.id))
        let rules = [
            NetworkRule(
                id: ruleIDs[0],
                name: "Mock profile",
                match: RuleMatch(url: URLMatcher(pattern: "/v1/profile")),
                action: .mapLocal(MockResponse(
                    statusCode: 200,
                    headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
                    body: #"{"name":"Aruzhan","tier":"gold"}"#
                ))
            ),
            NetworkRule(
                id: ruleIDs[1],
                name: "Force 503 on payments",
                match: RuleMatch(url: URLMatcher(pattern: "/payments")),
                action: .rewrite(request: nil, response: ResponseRewrite(statusCode: 503))
            ),
        ]
        for rule in rules where !existing.contains(rule.id) {
            RuleStore.shared.add(rule)
        }
    }

    static func seedTraffic() {
        let samples: [(String, String, Int?)] = [
            ("GET", "https://api.donk.dev/v1/profile", 200),
            ("GET", "https://api.donk.dev/v1/accounts?page=1", 200),
            ("POST", "https://api.donk.dev/v1/payments", 201),
            ("GET", "https://cdn.donk.dev/images/avatar.png", 200),
            ("PUT", "https://api.donk.dev/v1/settings", 204),
            ("GET", "https://api.donk.dev/v1/notifications", 401),
            ("DELETE", "https://api.donk.dev/v1/cards/42", 404),
            ("POST", "https://api.donk.dev/v1/transfers", 500),
            ("GET", "https://api.donk.dev/v1/rates", nil),
            ("GET", "https://api.donk.dev/v1/feed", 200),
        ]
        for (index, sample) in samples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(index) * 0.35) {
                record(method: sample.0, url: sample.1, status: sample.2)
            }
        }
    }

    static func record(method: String, url: String, status: Int?) {
        let started = Date()
        let entry = NetworkEntry(
            request: RequestSnapshot(
                url: url,
                method: method,
                headers: [
                    HTTPHeader(name: "Accept", value: "application/json"),
                    HTTPHeader(name: "Authorization", value: "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZW1vIn0.c2lnbmF0dXJl"),
                    HTTPHeader(name: "X-Request-ID", value: UUID().uuidString.lowercased()),
                ],
                body: method == "GET" ? nil : BodyData(text: #"{"amount":25000,"password":"hunter2"}"#, contentType: "application/json")
            ),
            timing: NetworkTiming(startedAt: started)
        )
        NetworkStore.shared.add(entry)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            NetworkStore.shared.update(entry.id) { entry in
                entry.timing.endedAt = Date()
                if let status {
                    entry.state = .completed
                    entry.response = ResponseSnapshot(
                        statusCode: status,
                        headers: [
                            HTTPHeader(name: "Content-Type", value: "application/json"),
                            HTTPHeader(name: "Access-Control-Allow-Credentials", value: "true"),
                            HTTPHeader(name: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains"),
                            HTTPHeader(name: "Set-Cookie", value: "session=9f86d081884c7d65; Path=/; HttpOnly; Secure"),
                        ],
                        body: BodyData(text: #"{"ok":\#(status < 400)}"#, contentType: "application/json")
                    )
                } else {
                    entry.state = .failed
                    entry.error = NetworkErrorInfo(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "The request timed out.")
                }
            }
        }
    }

    static func pauseSampleRequest(after delay: TimeInterval, resolveAfter: TimeInterval? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let entry = NetworkEntry(
                state: .paused,
                origin: .breakpoint(edited: false),
                request: RequestSnapshot(url: "https://api.donk.dev/v1/transfers", method: "POST")
            )
            NetworkStore.shared.add(entry)
            let exchange = PausedExchange(
                entryID: entry.id,
                kind: .http,
                phase: .request,
                ruleName: "Pause transfers",
                payload: .request(EditableRequest(
                    url: entry.request.url,
                    method: "POST",
                    headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
                    body: #"{"amount":25000,"currency":"KZT"}"#
                ))
            )
            if let resolveAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + resolveAfter) {
                    BreakpointCenter.shared.resolve(exchange.id, with: .resume(exchange.payload))
                }
            }
            Task.detached {
                let decision = await BreakpointCenter.shared.pause(exchange)
                NetworkStore.shared.update(entry.id) { entry in
                    switch decision {
                    case .abort:
                        entry.state = .cancelled
                    case .resume, .respond:
                        entry.state = .completed
                        entry.response = ResponseSnapshot(statusCode: 200)
                    }
                    entry.timing.endedAt = Date()
                }
            }
        }
    }
}
