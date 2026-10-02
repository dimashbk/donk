import Donk
import DonkUI
import SwiftUI
import UIKit

@MainActor
enum DemoDiagnostics {
    private static var probeTimer: Timer?
    private static var lastReport = ""

    static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    static func keyWindowReport() -> String {
        windows.map { window in
            let top = topViewController(in: window).map { String(describing: type(of: $0)) } ?? "none"
            let kind = window is DonkWindowMarker ? "donk" : "app"
            return "\(kind) \(type(of: window)) level=\(Int(window.windowLevel.rawValue)) key=\(window.isKeyWindow) hidden=\(window.isHidden) top=\(top)"
        }
        .joined(separator: "\n")
    }

    static func log(_ reason: String) {
        let report = keyWindowReport()
        let entry = "[\(reason)] \(Date())\n\(report)\n"
        print("DONK_KEY_PROBE \(entry)")
        guard let url = logURL else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("donk-key-probe.log")
    }

    static func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-DonkKeyProbe") {
            if let url = logURL {
                try? FileManager.default.removeItem(at: url)
            }
            startProbe()
        }
        if let delay = number(after: "-DonkHostPresentAfter", in: arguments) {
            presentLikeHost(after: delay)
        }
        if let delay = number(after: "-DonkHideAfter", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                log("before Donk.hide()")
                Donk.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("after Donk.hide()")
                }
            }
        }
        if arguments.contains("-DonkHostDark") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for window in windows where !(window is DonkWindowMarker) {
                    window.overrideUserInterfaceStyle = .dark
                    window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
                }
                log("host forced dark")
            }
        }
        if let delay = number(after: "-DonkExportProbeAfter", in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                logExports()
            }
        }
    }

    static func logExports() {
        let settings = NetworkSettingsStore.shared.settings
        guard let entry = NetworkStore.shared.snapshot().first(where: { $0.kind == .http && !$0.request.headers.isEmpty }) else {
            log("export probe: no HTTP entry")
            return
        }
        let command = CurlExporter.command(for: entry.request, redaction: settings.exportRedaction)
        DonkPasteboard.copy("donk pasteboard probe", showsToast: false)
        let pasted = UIPasteboard.general.string ?? "nil"
        log("export probe redactsExports=\(settings.redactsExports) pasteboard=\(pasted)\n\(command)")
    }

    private static func number(after flag: String, in arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return Double(arguments[index + 1])
    }

    static func startProbe() {
        probeTimer?.invalidate()
        log("probe started")
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let report = keyWindowReport()
                guard report != lastReport else { return }
                lastReport = report
                log("changed")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                let window = notification.object as? UIWindow
                let kind = window is DonkWindowMarker ? "donk" : "app"
                let typeName = window.map { String(describing: type(of: $0)) } ?? "nil"
                let event = name == UIWindow.didBecomeKeyNotification ? "didBecomeKey" : "didResignKey"
                MainActor.assumeIsolated { log("\(event) \(kind) \(typeName)") }
            }
        }
    }

    static func presentLikeHost(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let key = windows.first(where: \.isKeyWindow), let top = topViewController(in: key) else {
                log("host presentation skipped: no key window")
                return
            }
            let alert = UIAlertController(
                title: "Host screen",
                message: "Presented through a key-window lookup on \(type(of: key)).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(alert, animated: true)
            log("host presented on \(key is DonkWindowMarker ? "donk" : "app") window")
        }
    }

    private static func topViewController(in window: UIWindow) -> UIViewController? {
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

struct DemoDiagnosticsSection: View {
    @State private var report: String?

    var body: some View {
        Section {
            Button {
                DemoDiagnostics.log("menu")
                report = DemoDiagnostics.keyWindowReport()
            } label: {
                DonkLabelRow(icon: "macwindow.on.rectangle", tone: .neutral, title: "Key window report", subtitle: "Which window is key right now")
            }
            Button {
                DemoDiagnostics.presentLikeHost(after: 3)
            } label: {
                DonkLabelRow(icon: "rectangle.stack.badge.plus", tone: .warning, title: "Host presentation in 3 s", subtitle: "Open donk now; the alert must land on the app window")
            }
        } header: {
            DonkSectionHeader("Diagnostics")
        }
        .alert("Windows", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(report ?? "")
        }
    }
}
