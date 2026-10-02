import DonkCore
import Foundation
import ObjectiveC.runtime
import WebKit

// MARK: - Settings

final class WebCaptureSettings: @unchecked Sendable {
    static let shared = WebCaptureSettings()

    private struct Stored: Codable {
        var makesWebViewsInspectable: Bool
    }

    private static let fileName = "webview-settings.json"
    private let lock = DonkLock()
    private var automatic = false
    private var inspectable: Bool?

    var automaticAttach: Bool {
        get { lock.withLock { automatic } }
        set { lock.withLock { automatic = newValue } }
    }

    var makesWebViewsInspectable: Bool {
        get {
            lock.withLock {
                if let inspectable { return inspectable }
                let loaded = DonkPersistence.load(Stored.self, from: Self.fileName)?.makesWebViewsInspectable ?? false
                inspectable = loaded
                return loaded
            }
        }
        set {
            let changed: Bool = lock.withLock {
                guard inspectable != newValue else { return false }
                inspectable = newValue
                return true
            }
            guard changed else { return }
            DonkPersistence.save(Stored(makesWebViewsInspectable: newValue), to: Self.fileName)
        }
    }
}

// MARK: - Main thread

enum MainThread {
    static func run(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    static func sync<T>(_ body: @MainActor () -> T) -> T? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated(body)
    }
}

// MARK: - Tracking

final class WebViewTracker: NSObject {
    let id: String
    private(set) var isCaptureAttached = false
    var originalInspectable: Bool?
    private var observations: [NSKeyValueObservation] = []

    init(id: String) {
        self.id = id
    }

    deinit {
        observations.forEach { $0.invalidate() }
        if isCaptureAttached {
            WebCaptureEngine.shared.receiveNavigation(.gone, webViewID: id)
        }
    }

    @MainActor
    func attachCapture(to webView: WKWebView) {
        guard !isCaptureAttached else { return }
        isCaptureAttached = true
        let id = id
        let engine = WebCaptureEngine.shared
        let loading = webView.observe(\.isLoading, options: [.new]) { webView, change in
            let isLoading = change.newValue ?? false
            if isLoading {
                MainThread.sync { WebCaptureBridge.reattachIfNeeded(webView) }
            }
            let url = isLoading ? webView.url?.absoluteString : nil
            engine.receiveNavigation(isLoading ? .loadingStarted(url: url) : .loadingStopped, webViewID: id)
        }
        let url = webView.observe(\.url, options: [.new]) { webView, _ in
            engine.receiveNavigation(.urlChanged(url: webView.url?.absoluteString), webViewID: id)
        }
        observations = [loading, url]
        if webView.isLoading {
            engine.receiveNavigation(.loadingStarted(url: webView.url?.absoluteString), webViewID: id)
        }
    }
}

@MainActor
enum WebViewRegistry {
    private static var trackerKey: UInt8 = 0
    private static var counter = 0
    private static let webViews = NSHashTable<WKWebView>.weakObjects()

    static func tracker(for webView: WKWebView) -> WebViewTracker? {
        objc_getAssociatedObject(webView, &trackerKey) as? WebViewTracker
    }

    @discardableResult
    static func track(_ webView: WKWebView, attached: Bool) -> WebViewTracker {
        let tracker: WebViewTracker
        if let existing = self.tracker(for: webView) {
            tracker = existing
        } else {
            counter += 1
            tracker = WebViewTracker(id: "WV\(counter)")
            objc_setAssociatedObject(webView, &trackerKey, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            webViews.add(webView)
            if WebCaptureSettings.shared.makesWebViewsInspectable {
                WebCaptureBridge.applyInspectable(true, to: webView, tracker: tracker)
            }
        }
        if attached {
            tracker.attachCapture(to: webView)
        }
        return tracker
    }

    static var trackedWebViews: [WKWebView] {
        webViews.allObjects
    }
}

// MARK: - Script messages

@MainActor
final class ScriptMessageReceiver: NSObject, WKScriptMessageHandler {
    static let shared = ScriptMessageReceiver()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        WebCaptureBridge.handle(message)
    }
}

@MainActor
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Bridge

@MainActor
enum WebCaptureBridge {
    private static var attachedKey: UInt8 = 0
    private static var disabledPages = Set<String>()
    private static var disabledFrames: [(webView: WeakBox<WKWebView>, frame: WKFrameInfo)] = []
    private static let disabledFrameLimit = 256

    static func attach(_ controller: WKUserContentController) {
        guard !isAttached(controller) else { return }
        let script = WKUserScript(
            source: WebCaptureScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        )
        objc_setAssociatedObject(controller, &attachedKey, script, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        controller.addUserScript(script)
        controller.removeScriptMessageHandler(forName: WebCaptureScript.handlerName, contentWorld: .page)
        controller.add(WeakScriptMessageProxy(target: ScriptMessageReceiver.shared), contentWorld: .page, name: WebCaptureScript.handlerName)
    }

    static func isAttached(_ controller: WKUserContentController) -> Bool {
        guard let script = objc_getAssociatedObject(controller, &attachedKey) as? WKUserScript else { return false }
        return controller.userScripts.contains { $0 === script }
    }

    static func reattachIfNeeded(_ webView: WKWebView) {
        guard WebCaptureEngine.shared.isRecording, WebViewRegistry.tracker(for: webView)?.isCaptureAttached == true else { return }
        let controller = webView.configuration.userContentController
        guard !isAttached(controller) else { return }
        attach(controller)
    }

    static func captureTracker(for webView: WKWebView) -> WebViewTracker? {
        if let tracker = WebViewRegistry.tracker(for: webView), tracker.isCaptureAttached {
            return tracker
        }
        guard objc_getAssociatedObject(webView.configuration.userContentController, &attachedKey) != nil else { return nil }
        return WebViewRegistry.track(webView, attached: true)
    }

    static func handle(_ message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        let tracker = WebViewRegistry.track(webView, attached: true)
        let body = message.body
        let engine = WebCaptureEngine.shared
        guard engine.isRecording else {
            disable(message, webView: webView)
            return
        }
        let context = ScriptContext(
            webViewID: tracker.id,
            isMainFrame: message.frameInfo.isMainFrame,
            mainPageURL: webView.url?.absoluteString
        )
        engine.receiveScript(UncheckedBox(value: body), context: context)
    }

    static func didStart(automatic: Bool) {
        if automatic {
            for webView in WebViewRegistry.trackedWebViews where WebViewRegistry.tracker(for: webView)?.isCaptureAttached != true {
                attach(webView.configuration.userContentController)
                WebViewRegistry.track(webView, attached: true)
            }
        }
        setScriptsEnabled(true)
    }

    static func setScriptsEnabled(_ enabled: Bool) {
        let script = WebCaptureScript.setEnabledScript(enabled)
        for webView in WebViewRegistry.trackedWebViews {
            guard WebViewRegistry.tracker(for: webView)?.isCaptureAttached == true else { continue }
            webView.evaluateJavaScript(script, in: nil, in: .page, completionHandler: nil)
        }
        guard enabled else { return }
        for item in disabledFrames {
            item.webView.value?.evaluateJavaScript(script, in: item.frame, in: .page, completionHandler: nil)
        }
        disabledFrames.removeAll()
        disabledPages.removeAll()
    }

    static func applyInspectable(_ enabled: Bool) {
        for webView in WebViewRegistry.trackedWebViews {
            guard let tracker = WebViewRegistry.tracker(for: webView) else { continue }
            applyInspectable(enabled, to: webView, tracker: tracker)
        }
    }

    static func applyInspectable(_ enabled: Bool, to webView: WKWebView, tracker: WebViewTracker) {
        guard #available(iOS 16.4, *) else { return }
        if enabled {
            if tracker.originalInspectable == nil {
                tracker.originalInspectable = webView.isInspectable
            }
            if !webView.isInspectable {
                webView.isInspectable = true
            }
        } else if let original = tracker.originalInspectable {
            tracker.originalInspectable = nil
            if webView.isInspectable != original {
                webView.isInspectable = original
            }
        }
    }

    private static func disable(_ message: WKScriptMessage, webView: WKWebView) {
        guard let page = (message.body as? [String: Any])?["pg"] as? String, !disabledPages.contains(page) else { return }
        disabledPages.insert(page)
        let frame = message.frameInfo
        webView.evaluateJavaScript(WebCaptureScript.setEnabledScript(false), in: frame, in: .page, completionHandler: nil)
        if !frame.isMainFrame {
            disabledFrames.removeAll { $0.webView.value == nil }
            disabledFrames.append((WeakBox(webView), frame))
            if disabledFrames.count > disabledFrameLimit {
                disabledFrames.removeFirst(disabledFrames.count - disabledFrameLimit)
            }
        }
    }
}

final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
