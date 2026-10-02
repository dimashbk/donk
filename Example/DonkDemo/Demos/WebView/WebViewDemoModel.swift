import Combine
import Donk
import SwiftUI
import WebKit

@MainActor
final class WebViewDemoModel: ObservableObject {
    enum Site: String, CaseIterable, Identifiable {
        case example = "https://example.com/"
        case httpbin = "https://httpbin.org/html"
        case wikipedia = "https://en.m.wikipedia.org/wiki/Main_Page"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .example: return "example.com"
            case .httpbin: return "httpbin.org/html"
            case .wikipedia: return "Wikipedia (mobile)"
            }
        }

        var url: URL { URL(string: rawValue)! }
    }

    @Published private(set) var entries: [NetworkEntry] = []
    @Published private(set) var site: Site = .example
    @Published private(set) var siteTitle = ""
    @Published private(set) var siteIsLoading = false
    @Published private(set) var checks: [SelfCheck] = []
    @Published private(set) var isVerifying = false
    @Published var isInspectable: Bool {
        didSet { DonkWebViewCapture.makesWebViewsInspectable = isInspectable }
    }
    @Published var isCapturing: Bool {
        didSet {
            if isCapturing {
                DonkWebViewCapture.start()
            } else {
                DonkWebViewCapture.stop()
            }
        }
    }

    let playground: WKWebView
    let browser: WKWebView
    let robustness = WebRobustnessCheck()
    private let browserDelegate = BrowserNavigationDelegate()
    private var cancellables = Set<AnyCancellable>()
    private var verificationStartedAt: Date?
    private var verificationTimer: Timer?

    init() {
        DonkWebViewCapture.start()
        isInspectable = DonkWebViewCapture.makesWebViewsInspectable
        isCapturing = DonkWebViewCapture.isRunning

        let playgroundConfiguration = WKWebViewConfiguration()
        playgroundConfiguration.allowsInlineMediaPlayback = true
        playground = WKWebView(frame: .zero, configuration: playgroundConfiguration)
        playground.isOpaque = false
        playground.backgroundColor = .clear
        playground.scrollView.backgroundColor = .clear

        browser = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        browser.allowsBackForwardNavigationGestures = true
        browser.navigationDelegate = browserDelegate

        browserDelegate.onChange = { [weak self] webView in
            self?.siteTitle = webView.title ?? ""
            self?.siteIsLoading = webView.isLoading
        }

        NetworkStore.shared.events
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        playground.loadHTMLString(WebPlaygroundPage.html, baseURL: WebPlaygroundPage.baseURL)
        browser.load(URLRequest(url: site.url))
        reload()
    }

    var playgroundIdentifier: String {
        DonkWebViewCapture.identifier(for: playground) ?? "—"
    }

    var browserIdentifier: String {
        DonkWebViewCapture.identifier(for: browser) ?? "—"
    }

    func open(_ site: Site) {
        self.site = site
        browser.load(URLRequest(url: site.url))
    }

    func reloadSite() {
        browser.reload()
    }

    func reloadPlayground() {
        playground.loadHTMLString(WebPlaygroundPage.html, baseURL: WebPlaygroundPage.baseURL)
    }

    func runAll(attempt: Int = 0, started: ((Date?) -> Void)? = nil) {
        let script = "(function(){if(window.donkDemo){window.donkDemo.runAll();return true;}return false;})()"
        let date = Date()
        playground.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true {
                started?(date)
            } else if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runAll(attempt: attempt + 1, started: started) }
            } else {
                started?(nil)
            }
        }
    }

    func clear() {
        let ids = Set(NetworkStore.shared.snapshot().filter { $0.kind == .webView }.map(\.id))
        NetworkStore.shared.remove(ids)
        checks = []
        reload()
    }

    func verify() {
        verificationTimer?.invalidate()
        verificationStartedAt = nil
        isVerifying = true
        checks = SelfCheck.evaluate([], since: Date())
        runAll { [weak self] started in
            guard let self else { return }
            guard let started else {
                self.finishVerification()
                return
            }
            self.verificationStartedAt = started
            let deadline = started.addingTimeInterval(30)
            self.verificationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor [weak self] in
                    guard let self, let started = self.verificationStartedAt else { return }
                    self.checks = SelfCheck.evaluate(self.entries, since: started)
                    if self.checks.allSatisfy({ $0.status == .passed }) || Date() > deadline {
                        self.finishVerification()
                    }
                }
            }
        }
    }

    private func finishVerification() {
        verificationTimer?.invalidate()
        verificationTimer = nil
        isVerifying = false
        checks = checks.map { check in
            var check = check
            if check.status == .pending { check.status = .failed }
            return check
        }
    }

    private func reload() {
        entries = Array(NetworkStore.shared.snapshot().lazy.filter { $0.kind == .webView }.prefix(200))
    }
}

@MainActor
final class BrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var onChange: ((WKWebView) -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onChange?(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onChange?(webView)
    }
}

// MARK: - Self check

struct SelfCheck: Identifiable, Equatable {
    enum Status: Equatable { case pending, passed, failed }

    let id: String
    let title: String
    var detail: String
    var status: Status

    private struct Rule {
        let id: String
        let title: String
        let expectation: String
        let usesWindow: Bool
        let matches: (NetworkEntry) -> Bool
        let detail: (NetworkEntry) -> String
    }

    static func evaluate(_ entries: [NetworkEntry], since start: Date) -> [SelfCheck] {
        let recent = entries.filter { $0.timing.startedAt >= start.addingTimeInterval(-1) }
        return rules.map { rule in
            let pool = rule.usesWindow ? recent : entries
            if let match = pool.first(where: rule.matches) {
                return SelfCheck(id: rule.id, title: rule.title, detail: rule.detail(match), status: .passed)
            }
            return SelfCheck(id: rule.id, title: rule.title, detail: rule.expectation, status: .pending)
        }
    }

    private static func body(_ body: BodyData?) -> String {
        guard let body else { return "no body" }
        return "\(body.originalSize) B body\(body.isTruncated ? " (truncated)" : "")"
    }

    private static let rules: [Rule] = [
        Rule(
            id: "document", title: "Page document", expectation: "document entry for https://donk.demo/", usesWindow: false,
            matches: { $0.web?.initiator == .document && $0.request.url.hasPrefix("https://donk.demo") && $0.state == .completed },
            detail: { "\($0.web?.captureLevel.rawValue ?? "") · \($0.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")" }
        ),
        Rule(
            id: "fetch-get", title: "fetch GET + response body", expectation: "200 with JSON body containing userId", usesWindow: true,
            matches: { $0.web?.initiator == .fetch && $0.request.url.contains("jsonplaceholder") && $0.response?.statusCode == 200 && ($0.response?.body?.text?.contains("userId") ?? false) },
            detail: { "200 · response \(body($0.response?.body))" }
        ),
        Rule(
            id: "fetch-post", title: "fetch POST + request body", expectation: "JSON request body and echoed response", usesWindow: true,
            matches: { $0.web?.initiator == .fetch && $0.request.method == "POST" && ($0.request.body?.text?.contains("webview-capture") ?? false) && ($0.response?.body?.text?.contains("\"json\"") ?? false) },
            detail: { "request \(body($0.request.body)) · response \(body($0.response?.body))" }
        ),
        Rule(
            id: "xhr-get", title: "XHR GET + custom header", expectation: "X-Donk-Demo header and 200 body", usesWindow: true,
            matches: { $0.web?.initiator == .xhr && $0.request.method == "GET" && $0.request.header("X-Donk-Demo") == "xhr-get" && $0.response?.statusCode == 200 && ($0.response?.body?.text?.contains("X-Donk-Demo") ?? false) },
            detail: { "\($0.request.headers.count) request headers · response \(body($0.response?.body))" }
        ),
        Rule(
            id: "xhr-post", title: "XHR POST + form body", expectation: "form body and JSON response", usesWindow: true,
            matches: { $0.web?.initiator == .xhr && $0.request.method == "POST" && ($0.request.body?.text?.contains("user=donk") ?? false) && ($0.response?.body?.text?.contains("\"form\"") ?? false) },
            detail: { "request \(body($0.request.body)) · response \(body($0.response?.body))" }
        ),
        Rule(
            id: "not-found", title: "HTTP 404", expectation: "fetch entry with status 404", usesWindow: true,
            matches: { $0.web?.initiator == .fetch && $0.response?.statusCode == 404 },
            detail: { "\($0.statusLabel) · \($0.statusCategory.rawValue)" }
        ),
        Rule(
            id: "network-error", title: "Network error", expectation: "failed fetch with error message", usesWindow: true,
            matches: { $0.web?.initiator == .fetch && $0.state == .failed && $0.request.url.contains("donk.invalid") },
            detail: { $0.error?.message ?? "failed" }
        ),
        Rule(
            id: "beacon", title: "sendBeacon + Blob body", expectation: "beacon entry with request body", usesWindow: true,
            matches: { $0.web?.initiator == .beacon && ($0.request.body?.text?.contains("demo_beacon") ?? false) },
            detail: { "request \(body($0.request.body))" }
        ),
        Rule(
            id: "binary", title: "Binary response", expectation: "image/png body captured", usesWindow: true,
            matches: { $0.web?.initiator == .fetch && $0.request.url.contains("image/png") && ($0.response?.body?.isImage ?? false) },
            detail: { "response \(body($0.response?.body))" }
        ),
        Rule(
            id: "websocket", title: "WebSocket", expectation: "101 then closed", usesWindow: true,
            matches: { $0.web?.initiator == .websocket && $0.response?.statusCode == 101 && !$0.state.isInFlight },
            detail: { $0.response?.body?.text?.components(separatedBy: "\n").prefix(2).joined(separator: " · ") ?? "" }
        ),
        Rule(
            id: "event-source", title: "EventSource", expectation: "stream opened and closed", usesWindow: true,
            matches: { $0.web?.initiator == .eventSource && $0.response?.statusCode == 200 && !$0.state.isInFlight },
            detail: { $0.response?.body?.text?.components(separatedBy: "\n").first ?? "" }
        ),
        Rule(
            id: "resources", title: "Images (resource timing)", expectation: "observed picsum.photos entries", usesWindow: true,
            matches: { $0.web?.initiator == .resource && $0.request.url.contains("picsum") },
            detail: { "\($0.web?.captureLevel.rawValue ?? "") · \($0.duration.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")" }
        ),
        Rule(
            id: "iframe", title: "Iframe document", expectation: "sub-frame document for example.com", usesWindow: true,
            matches: { $0.web?.initiator == .document && $0.request.url.contains("example.com") && ($0.web?.pageURL?.contains("donk.demo") ?? false) },
            detail: { "\($0.statusLabel) · \($0.web?.captureLevel.rawValue ?? "")" }
        ),
    ]
}
