import DonkCore
import Foundation
import ObjectiveC.runtime
import WebKit

enum MethodHook {
    @discardableResult
    static func wrap(_ cls: AnyClass, _ selector: Selector, makeBlock: (IMP) -> Any) -> Bool {
        guard let method = class_getInstanceMethod(cls, selector) else { return false }
        let block = makeBlock(method_getImplementation(method))
        let implementation = imp_implementationWithBlock(block)
        if class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            return true
        }
        guard let own = class_getInstanceMethod(cls, selector) else { return false }
        method_setImplementation(own, implementation)
        return true
    }
}

// MARK: - WKWebView

enum WebViewSwizzles {
    private final class State: @unchecked Sendable {
        let lock = DonkLock()
        var didInstallInit = false
        var didInstallDelegate = false
    }

    private static let state = State()

    static func installInitHooks() {
        let shouldInstall: Bool = state.lock.withLock {
            guard !state.didInstallInit else { return false }
            state.didInstallInit = true
            return true
        }
        guard shouldInstall else { return }
        hookInitWithFrame()
        hookInitWithCoder()
    }

    static func installNavigationDelegateHook() {
        let shouldInstall: Bool = state.lock.withLock {
            guard !state.didInstallDelegate else { return false }
            state.didInstallDelegate = true
            return true
        }
        guard shouldInstall else { return }
        hookSetNavigationDelegate()
    }

    private static func hookInitWithFrame() {
        let selector = #selector(WKWebView.init(frame:configuration:))
        MethodHook.wrap(WKWebView.self, selector) { implementation in
            typealias Original = @convention(c) (UnsafeMutableRawPointer, Selector, CGRect, WKWebViewConfiguration?) -> UnsafeMutableRawPointer?
            let original = unsafeBitCast(implementation, to: Original.self)
            let block: @convention(block) (UnsafeMutableRawPointer, CGRect, WKWebViewConfiguration?) -> UnsafeMutableRawPointer? = { receiver, frame, configuration in
                MainThread.sync { WebViewLifecycle.willInitialize(configuration) }
                let result = original(receiver, selector, frame, configuration)
                if let result {
                    let webView = Unmanaged<AnyObject>.fromOpaque(result).takeUnretainedValue()
                    if let webView = webView as? WKWebView {
                        MainThread.sync { WebViewLifecycle.didInitialize(webView, configuration: configuration) }
                    }
                }
                return result
            }
            return block
        }
    }

    private static func hookInitWithCoder() {
        let selector = #selector(WKWebView.init(coder:))
        MethodHook.wrap(WKWebView.self, selector) { implementation in
            typealias Original = @convention(c) (UnsafeMutableRawPointer, Selector, NSCoder?) -> UnsafeMutableRawPointer?
            let original = unsafeBitCast(implementation, to: Original.self)
            let block: @convention(block) (UnsafeMutableRawPointer, NSCoder?) -> UnsafeMutableRawPointer? = { receiver, coder in
                let result = original(receiver, selector, coder)
                if let result {
                    let webView = Unmanaged<AnyObject>.fromOpaque(result).takeUnretainedValue()
                    if let webView = webView as? WKWebView {
                        MainThread.sync { WebViewLifecycle.didInitializeFromCoder(webView) }
                    }
                }
                return result
            }
            return block
        }
    }

    private static func hookSetNavigationDelegate() {
        let selector = #selector(setter: WKWebView.navigationDelegate)
        MethodHook.wrap(WKWebView.self, selector) { implementation in
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(implementation, to: Original.self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { receiver, delegate in
                if let delegate, let webView = receiver as? WKWebView {
                    MainThread.sync { WebViewLifecycle.willSetNavigationDelegate(delegate, on: webView) }
                }
                original(receiver, selector, delegate)
            }
            return block
        }
    }
}

// MARK: - Lifecycle

@MainActor
enum WebViewLifecycle {
    static func willInitialize(_ configuration: WKWebViewConfiguration?) {
        guard let configuration, WebCaptureEngine.shared.isRecording, WebCaptureSettings.shared.automaticAttach else { return }
        WebCaptureBridge.attach(configuration.userContentController)
    }

    static func didInitialize(_ webView: WKWebView, configuration: WKWebViewConfiguration?) {
        let attached = configuration.map { WebCaptureBridge.isAttached($0.userContentController) } ?? false
        WebViewRegistry.track(webView, attached: attached)
    }

    static func didInitializeFromCoder(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if WebCaptureEngine.shared.isRecording, WebCaptureSettings.shared.automaticAttach {
            WebCaptureBridge.attach(controller)
        }
        WebViewRegistry.track(webView, attached: WebCaptureBridge.isAttached(controller))
    }

    static func willSetNavigationDelegate(_ delegate: AnyObject, on webView: WKWebView) {
        guard WebCaptureEngine.shared.isRecording, WebCaptureBridge.captureTracker(for: webView) != nil else { return }
        NavigationDelegateHooks.install(for: delegate)
    }
}

// MARK: - Navigation delegate

enum NavigationDelegateHooks {
    typealias DecisionHandler = @convention(block) (WKNavigationResponsePolicy) -> Void

    private final class State: @unchecked Sendable {
        let lock = DonkLock()
        var hooked = Set<ObjectIdentifier>()
    }

    private static let state = State()

    static let decideResponse = NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")
    static let didFinish = NSSelectorFromString("webView:didFinishNavigation:")
    static let didFail = NSSelectorFromString("webView:didFailNavigation:withError:")
    static let didFailProvisional = NSSelectorFromString("webView:didFailProvisionalNavigation:withError:")

    private static let forwardingSelectors: [Selector] = [
        #selector(NSObject.responds(to:)),
        #selector(NSObject.forwardingTarget(for:)),
        NSSelectorFromString("forwardInvocation:"),
    ]

    @discardableResult
    static func install(for delegate: AnyObject) -> Bool {
        guard var cls: AnyClass = object_getClass(delegate) else { return false }
        if NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let superclass = class_getSuperclass(cls) {
            cls = superclass
        }
        let identifier = ObjectIdentifier(cls)
        let shouldHook: Bool = state.lock.withLock {
            state.hooked.insert(identifier).inserted
        }
        guard shouldHook, !forwardsMessages(cls) else { return false }
        var wrapped = false
        wrapped = hookDecideResponse(cls) || wrapped
        wrapped = hookFinish(cls) || wrapped
        wrapped = hookFailure(cls, selector: didFail, provisional: false) || wrapped
        wrapped = hookFailure(cls, selector: didFailProvisional, provisional: true) || wrapped
        return wrapped
    }

    static func forwardsMessages(_ cls: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let candidate = current {
            if candidate === NSProxy.self { return true }
            current = class_getSuperclass(candidate)
        }
        let base: AnyClass = NSObject.self
        return forwardingSelectors.contains { selector in
            class_getMethodImplementation(cls, selector) != class_getMethodImplementation(base, selector)
        }
    }

    private static func hookDecideResponse(_ cls: AnyClass) -> Bool {
        let selector = decideResponse
        guard class_getInstanceMethod(cls, selector) != nil else { return false }
        return MethodHook.wrap(cls, selector) { implementation in
            typealias Original = @convention(c) (AnyObject, Selector, WKWebView, WKNavigationResponse, @escaping DecisionHandler) -> Void
            let original = unsafeBitCast(implementation, to: Original.self)
            let block: @convention(block) (AnyObject, WKWebView, WKNavigationResponse, @escaping DecisionHandler) -> Void = { receiver, webView, response, handler in
                guard let token = MainThread.sync({ NavigationRecorder.recordResponse(response, in: webView) }) ?? nil else {
                    original(receiver, selector, webView, response, handler)
                    return
                }
                let wrapped: DecisionHandler = { policy in
                    NavigationRecorder.recordDecision(token, policy: policy)
                    handler(policy)
                }
                original(receiver, selector, webView, response, wrapped)
            }
            return block
        }
    }

    private static func hookFinish(_ cls: AnyClass) -> Bool {
        let selector = didFinish
        guard class_getInstanceMethod(cls, selector) != nil else { return false }
        return MethodHook.wrap(cls, selector) { implementation in
            typealias Original = @convention(c) (AnyObject, Selector, WKWebView, WKNavigation?) -> Void
            let original = unsafeBitCast(implementation, to: Original.self)
            let block: @convention(block) (AnyObject, WKWebView, WKNavigation?) -> Void = { receiver, webView, navigation in
                MainThread.sync { NavigationRecorder.recordFinish(navigation, in: webView) }
                original(receiver, selector, webView, navigation)
            }
            return block
        }
    }

    private static func hookFailure(_ cls: AnyClass, selector: Selector, provisional: Bool) -> Bool {
        guard class_getInstanceMethod(cls, selector) != nil else { return false }
        return MethodHook.wrap(cls, selector) { implementation in
            typealias Original = @convention(c) (AnyObject, Selector, WKWebView, WKNavigation?, NSError?) -> Void
            let original = unsafeBitCast(implementation, to: Original.self)
            let block: @convention(block) (AnyObject, WKWebView, WKNavigation?, NSError?) -> Void = { receiver, webView, navigation, error in
                MainThread.sync { NavigationRecorder.recordFailure(error, navigation: navigation, provisional: provisional, in: webView) }
                original(receiver, selector, webView, navigation, error)
            }
            return block
        }
    }
}

// MARK: - Recorder

struct DecisionToken: Sendable {
    let id: UUID
    let webViewID: String
}

@MainActor
enum NavigationRecorder {
    private static var responseKey: UInt8 = 0
    private static var finishKey: UInt8 = 0
    private static var failureKey: UInt8 = 0

    static func recordResponse(_ navigationResponse: WKNavigationResponse, in webView: WKWebView) -> DecisionToken? {
        guard WebCaptureEngine.shared.isRecording, let tracker = WebCaptureBridge.captureTracker(for: webView) else { return nil }
        guard objc_getAssociatedObject(navigationResponse, &responseKey) == nil else { return nil }
        objc_setAssociatedObject(navigationResponse, &responseKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let urlResponse = navigationResponse.response
        guard let url = urlResponse.url?.absoluteString else { return nil }
        let statusCode: Int
        var headers: [HTTPHeader]
        if let http = urlResponse as? HTTPURLResponse {
            statusCode = http.statusCode
            headers = HTTPHeader.list(from: http.allHeaderFields)
        } else {
            statusCode = 0
            headers = []
            if let mime = urlResponse.mimeType {
                let encoding = urlResponse.textEncodingName.map { "; charset=\($0)" } ?? ""
                headers.append(HTTPHeader(name: "Content-Type", value: mime + encoding))
            }
            if urlResponse.expectedContentLength >= 0 {
                headers.append(HTTPHeader(name: "Content-Length", value: String(urlResponse.expectedContentLength)))
            }
        }
        let token = DecisionToken(id: UUID(), webViewID: tracker.id)
        let response = DocumentResponse(
            token: token.id,
            url: url,
            isMainFrame: navigationResponse.isForMainFrame,
            statusCode: statusCode,
            headers: headers,
            pageURL: navigationResponse.isForMainFrame ? url : webView.url?.absoluteString
        )
        WebCaptureEngine.shared.receiveNavigation(.response(response), webViewID: tracker.id)
        return token
    }

    nonisolated static func recordDecision(_ token: DecisionToken, policy: WKNavigationResponsePolicy) {
        WebCaptureEngine.shared.receiveNavigation(.decision(token: token.id, policy: policy.rawValue), webViewID: token.webViewID)
    }

    static func recordFinish(_ navigation: WKNavigation?, in webView: WKWebView) {
        guard let tracker = WebCaptureBridge.captureTracker(for: webView), markOnce(navigation, key: &finishKey) else { return }
        WebCaptureEngine.shared.receiveNavigation(.finished, webViewID: tracker.id)
    }

    static func recordFailure(_ error: NSError?, navigation: WKNavigation?, provisional: Bool, in webView: WKWebView) {
        guard let error, let tracker = WebCaptureBridge.captureTracker(for: webView), markOnce(navigation, key: &failureKey) else { return }
        let isCancellation = (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
        let failingURL = (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        var info = NetworkErrorInfo(error)
        if provisional, !info.message.isEmpty {
            info.message += " (provisional navigation)"
        }
        WebCaptureEngine.shared.receiveNavigation(.failed(error: info, failingURL: failingURL, isCancellation: isCancellation), webViewID: tracker.id)
    }

    private static func markOnce(_ navigation: WKNavigation?, key: UnsafeRawPointer) -> Bool {
        guard let navigation else { return true }
        guard objc_getAssociatedObject(navigation, key) == nil else { return false }
        objc_setAssociatedObject(navigation, key, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }
}
