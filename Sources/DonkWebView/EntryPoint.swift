import DonkCore
import WebKit

public enum DonkWebViewCapture {
    public static func start(automatic: Bool = true) {
        let engine = WebCaptureEngine.shared
        let wasRecording = engine.isRecording
        WebCaptureSettings.shared.automaticAttach = automatic
        engine.isRecording = true
        WebViewSwizzles.installNavigationDelegateHook()
        if automatic || WebCaptureSettings.shared.makesWebViewsInspectable {
            WebViewSwizzles.installInitHooks()
        }
        guard !wasRecording else { return }
        MainThread.run {
            WebCaptureBridge.didStart(automatic: automatic)
        }
    }

    public static func stop() {
        let engine = WebCaptureEngine.shared
        guard engine.isRecording else { return }
        engine.isRecording = false
        engine.cancelInFlight()
        MainThread.run {
            WebCaptureBridge.setScriptsEnabled(false)
        }
    }

    public static func attach(to configuration: WKWebViewConfiguration) {
        let box = UncheckedBox(value: configuration)
        MainThread.run {
            WebCaptureBridge.attach(box.value.userContentController)
        }
    }

    public static var makesWebViewsInspectable: Bool {
        get { WebCaptureSettings.shared.makesWebViewsInspectable }
        set {
            WebCaptureSettings.shared.makesWebViewsInspectable = newValue
            if newValue {
                WebViewSwizzles.installInitHooks()
            }
            MainThread.run {
                WebCaptureBridge.applyInspectable(newValue)
            }
        }
    }

    public static var isRunning: Bool {
        WebCaptureEngine.shared.isRecording
    }

    @MainActor
    public static func attach(to webView: WKWebView) {
        WebCaptureBridge.attach(webView.configuration.userContentController)
        WebViewRegistry.track(webView, attached: true)
        guard isRunning, let delegate = webView.navigationDelegate else { return }
        WebViewSwizzles.installNavigationDelegateHook()
        NavigationDelegateHooks.install(for: delegate)
    }

    @MainActor
    public static func identifier(for webView: WKWebView) -> String? {
        WebViewRegistry.tracker(for: webView)?.id
    }
}
