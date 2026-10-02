import Donk
import DonkUI
import ObjectiveC.runtime
import SwiftUI
import WebKit

@MainActor
final class WebRobustnessCheck: ObservableObject {
    struct Result: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String
        var status: SelfCheck.Status
    }

    private enum Scenario: String, CaseIterable {
        case forwardingDelegate, removedScripts, stopCancels, requestBody

        var title: String {
            switch self {
            case .forwardingDelegate: return "Forwarding delegate untouched"
            case .removedScripts: return "Survives removeAllUserScripts()"
            case .stopCancels: return "Stop cancels in-flight entries"
            case .requestBody: return "fetch(Request) body capped"
            }
        }

        var expectation: String {
            switch self {
            case .forwardingDelegate: return "no methods added to the proxy class, later targets still get didFinish"
            case .removedScripts: return "fetch captured after the app removed every user script"
            case .stopCancels: return "pending fetch becomes cancelled when capture stops"
            case .requestBody: return "300 KB Request body captured as a 256 KB prefix"
            }
        }
    }

    @Published private(set) var results: [Result] = []
    @Published private(set) var isRunning = false

    private var webViews: [WKWebView] = []
    private var delegates: [NSObject] = []

    func run() {
        guard !isRunning else { return }
        isRunning = true
        results = Scenario.allCases.map { Result(id: $0.rawValue, title: $0.title, detail: $0.expectation, status: .pending) }
        Task { @MainActor in
            await record(.forwardingDelegate) { try await self.forwardingDelegate() }
            await record(.removedScripts) { try await self.removedScripts() }
            await record(.stopCancels) { try await self.stopCancels() }
            await record(.requestBody) { try await self.requestBody() }
            webViews.removeAll()
            delegates.removeAll()
            isRunning = false
        }
    }

    private func record(_ scenario: Scenario, _ body: () async throws -> String) async {
        let outcome: (SelfCheck.Status, String)
        do {
            outcome = (.passed, try await body())
        } catch {
            outcome = (.failed, (error as? CheckFailure)?.message ?? error.localizedDescription)
        }
        if let index = results.firstIndex(where: { $0.id == scenario.rawValue }) {
            results[index].status = outcome.0
            results[index].detail = outcome.1
        }
        print("[donk-robustness] \(scenario.rawValue): \(outcome.0 == .passed ? "PASS" : "FAIL") — \(outcome.1)")
    }

    // MARK: - Scenarios

    private func forwardingDelegate() async throws -> String {
        let silent = SilentNavigationTarget()
        let finishing = FinishingNavigationTarget()
        let first = ForwardingNavigationDelegate(target: silent)
        let second = ForwardingNavigationDelegate(target: finishing)
        delegates += [silent, finishing, first, second]
        let one = makeWebView()
        one.navigationDelegate = first
        try await load(one, html: "<html><body>forwarding one</body></html>", path: "forwarding-one")
        let two = makeWebView()
        two.navigationDelegate = second
        try await load(two, html: "<html><body>forwarding two</body></html>", path: "forwarding-two")
        let added = [
            "webView:didFinishNavigation:",
            "webView:didFailNavigation:withError:",
            "webView:didFailProvisionalNavigation:withError:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
        ].filter { class_getInstanceMethod(ForwardingNavigationDelegate.self, NSSelectorFromString($0)) != nil }
        guard added.isEmpty else { throw CheckFailure("methods added to proxy: \(added.joined(separator: ", "))") }
        try await waitUntil(timeout: 5) { finishing.finishCount > 0 }
        let id = DonkWebViewCapture.identifier(for: two)
        let document = try await entry(timeout: 8) { $0.web?.initiator == .document && $0.web?.webViewID == id && $0.state == .completed }
        return "didFinish reached target \(finishing.finishCount)× · document \(document.web?.captureLevel.rawValue ?? "")"
    }

    private func removedScripts() async throws -> String {
        let webView = makeWebView()
        try await load(webView, html: "<html><body>before removal</body></html>", path: "scripts-before")
        webView.configuration.userContentController.removeAllUserScripts()
        let marker = "donk-reattach-\(Int(Date().timeIntervalSince1970))"
        let html = "<html><body><script>fetch('https://httpbin.org/get?\(marker)').catch(function(){});</script></body></html>"
        try await load(webView, html: html, path: "scripts-after")
        let id = DonkWebViewCapture.identifier(for: webView)
        let captured = try await entry(timeout: 15) { $0.web?.initiator == .fetch && $0.request.url.contains(marker) && $0.web?.webViewID == id }
        return "fetch captured (\(captured.statusLabel)) after removal"
    }

    private func stopCancels() async throws -> String {
        let webView = makeWebView()
        let marker = "donk-inflight-\(Int(Date().timeIntervalSince1970))"
        let html = "<html><body><script>fetch('https://httpbin.org/delay/6?\(marker)').catch(function(){});</script></body></html>"
        try await load(webView, html: html, path: "inflight")
        let pending = try await entry(timeout: 10) { $0.request.url.contains(marker) && $0.state.isInFlight }
        DonkWebViewCapture.stop()
        defer { DonkWebViewCapture.start() }
        let finished = try await entry(timeout: 5) { $0.id == pending.id && !$0.state.isInFlight }
        guard finished.state == .cancelled else { throw CheckFailure("state is \(finished.state.rawValue)") }
        return finished.error?.message ?? "cancelled"
    }

    private func requestBody() async throws -> String {
        let webView = makeWebView()
        let marker = "donk-request-body-\(Int(Date().timeIntervalSince1970))"
        let script = "fetch(new Request('https://httpbin.org/post?\(marker)', {method: 'POST', headers: {'Content-Type': 'text/plain'}, body: 'x'.repeat(300000)})).catch(function(){});"
        try await load(webView, html: "<html><body><script>\(script)</script></body></html>", path: "request-body")
        let captured = try await entry(timeout: 15) { $0.request.url.contains(marker) && $0.request.body?.originalSize == 300_000 }
        let body = try unwrap(captured.request.body)
        guard body.isTruncated, body.data.count <= 256 * 1024 else { throw CheckFailure("captured \(body.data.count) B, truncated \(body.isTruncated)") }
        return "captured \(DonkFormat.bytes(Int64(body.data.count))) of \(DonkFormat.bytes(Int64(body.originalSize)))"
    }

    // MARK: - Helpers

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: WKWebViewConfiguration())
        webViews.append(webView)
        return webView
    }

    private func load(_ webView: WKWebView, html: String, path: String) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://donk.demo/robustness/\(path)"))
        try await waitUntil(timeout: 10) { webView.isLoading }
        try await waitUntil(timeout: 10) { !webView.isLoading }
    }

    private func entry(timeout: TimeInterval, _ matches: @escaping (NetworkEntry) -> Bool) async throws -> NetworkEntry {
        var found: NetworkEntry?
        try await waitUntil(timeout: timeout) {
            found = NetworkStore.shared.snapshot().first(where: matches)
            return found != nil
        }
        return try unwrap(found)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !condition() { throw CheckFailure("timed out after \(Int(timeout)) s") }
    }

    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw CheckFailure("missing value") }
        return value
    }
}

private struct CheckFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

final class ForwardingNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var target: NSObject?

    init(target: NSObject) {
        self.target = target
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (target?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let target, target.responds(to: aSelector) else { return super.forwardingTarget(for: aSelector) }
        return target
    }
}

final class SilentNavigationTarget: NSObject, WKNavigationDelegate {}

final class FinishingNavigationTarget: NSObject, WKNavigationDelegate {
    private(set) var finishCount = 0

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishCount += 1
    }
}

// MARK: - Card

struct RobustnessCheckCard: View {
    @ObservedObject var check: WebRobustnessCheck

    var body: some View {
        DonkCard(title: "Robustness", icon: "shield.lefthalf.filled", tone: .info) {
            Text("Forwarding delegates, scripts removed by the app, stopping mid-request and large Request bodies.")
                .font(DonkFont.footnote)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !check.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(check.results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            icon(for: result.status)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(DonkFont.callout.weight(.semibold))
                                    .foregroundColor(DonkColor.textPrimary)
                                Text(result.detail)
                                    .font(DonkFont.caption)
                                    .foregroundColor(DonkColor.textSecondary)
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        if result.id != check.results.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } accessory: {
            Button {
                check.run()
            } label: {
                if check.isRunning {
                    ProgressView()
                } else {
                    Text(check.results.isEmpty ? "Run" : "Run again")
                        .font(DonkFont.label)
                }
            }
            .disabled(check.isRunning)
        }
    }

    @ViewBuilder
    private func icon(for status: SelfCheck.Status) -> some View {
        switch status {
        case .pending:
            ProgressView().scaleEffect(0.7)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(DonkColor.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundColor(DonkColor.error)
        }
    }
}
