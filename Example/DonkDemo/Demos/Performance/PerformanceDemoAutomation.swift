import Donk
import DonkUI
import SwiftUI
import UIKit

enum PerformanceDemoScenario: String {
    case demo
    case hud
    case burnDashboard
    case dashboard
    case dashboardReopen
    case dashboardEvents
    case hangToast
    case hangDetail
    case keyboard
    case keyboardAbove
    case debuggerDashboard
    case jank
}

enum PerformanceDemoAutomation {
    private static var didBootstrap = false

    static var requestedScenario: PerformanceDemoScenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DonkPerfDemo"), index + 1 < arguments.count else { return nil }
        return PerformanceDemoScenario(rawValue: arguments[index + 1])
    }

    static func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard let scenario = requestedScenario else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            present(scenario)
        }
    }

    private static func present(_ scenario: PerformanceDemoScenario) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        let root = DonkNavigationContainer {
            PerformanceDemoView(scenario: scenario)
        }
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: false)
        if ProcessInfo.processInfo.arguments.contains("-DonkPerfDumpEvents") {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                dumpEvents()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-DonkPerfProbeHUD") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                probeHUD()
            }
        }
    }

    static var scrollFraction: CGFloat? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DonkPerfScroll"), index + 1 < arguments.count,
              let value = Double(arguments[index + 1]) else { return nil }
        return CGFloat(value)
    }

    static func scrollPresentedContent(to fraction: CGFloat) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        guard let view = top.view, let scrollView = largestScrollView(in: view) else { return }
        let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        let offset = -scrollView.adjustedContentInset.top + (maxOffset + scrollView.adjustedContentInset.top) * min(max(fraction, 0), 1)
        scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }

    private static func largestScrollView(in view: UIView) -> UIScrollView? {
        var best: UIScrollView?
        var queue = [view]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let scrollView = current as? UIScrollView, scrollView.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scrollView
            }
            queue.append(contentsOf: current.subviews)
        }
        return best
    }

    static func dumpEvents() {
        let text = DonkPerformance.recentEvents.reversed().map { event in
            "\(event.date) \(event.title)\n\(event.backtrace?.text ?? "no stack")\n"
        }.joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("donk-events.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func probeHUD() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows where window.accessibilityIdentifier == "donk.performance.hud" {
            var hits: [CGPoint] = []
            let bounds = window.bounds
            var y: CGFloat = 0
            while y < bounds.height {
                var x: CGFloat = 0
                while x < bounds.width {
                    let point = CGPoint(x: x, y: y)
                    if window.hitTest(point, with: nil) != nil {
                        hits.append(point)
                    }
                    x += 4
                }
                y += 4
            }
            let minX = hits.map(\.x).min() ?? -1
            let maxX = hits.map(\.x).max() ?? -1
            let minY = hits.map(\.y).min() ?? -1
            let maxY = hits.map(\.y).max() ?? -1
            let others = windows.filter { $0 !== window }.map { "\(type(of: $0)):\($0.windowLevel.rawValue):\($0.isHidden ? "hidden" : "visible")" }.joined(separator: ", ")
            let line = "windows=[\(others)] DONK_HUD_PROBE level=\(window.windowLevel.rawValue) key=\(window.isKeyWindow) hits=\(hits.count) box=(\(minX),\(minY))-(\(maxX),\(maxY)) bounds=\(bounds)\n"
            let frame = CGRect(x: 0, y: bounds.height - 300, width: bounds.width, height: 300)
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)])
            let raised = window.windowLevel.rawValue
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)])
            let restored = window.windowLevel.rawValue
            let report = line + "synthetic keyboard: raised=\(raised) restored=\(restored)\n"
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("donk-hud-probe.txt")
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
