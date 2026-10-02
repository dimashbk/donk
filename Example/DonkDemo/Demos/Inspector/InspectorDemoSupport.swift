import Donk
import DonkUI
import SwiftUI
import UIKit

@MainActor
enum InspectorDemoSupport {
    private static var isPrepared = false
    private static var didRunAutorun = false
    private static var debuggerWindow: DonkKeyWindow?

    static func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        DonkInspector.onWillStart = { hideDebugger() }
        DonkInspector.onOpenDebugger = { showDebugger() }
        scheduleAutorunIfNeeded()
    }

    static func showDebugger() {
        guard let scene = activeScene else { return }
        let window = debuggerWindow ?? DonkKeyWindow(
            windowScene: scene,
            rootViewController: UIHostingController(rootView: DemoInspectorDebugger().donkTheme())
        )
        debuggerWindow = window
        window.present()
    }

    static func hideDebugger() {
        guard let window = debuggerWindow, !window.isHidden else { return }
        window.dismiss()
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    // MARK: - Autorun

    private static func scheduleAutorunIfNeeded() {
        guard !didRunAutorun, let command = autorunCommand else { return }
        didRunAutorun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            presentPlayground(for: command)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                run(command)
            }
        }
    }

    private static var autorunCommand: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DonkInspectorDemo"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func presentPlayground(for command: String) {
        guard command != "settings" else { return }
        let tab: InspectorPlaygroundTab = command.hasPrefix("swiftui") ? .swiftUI : .uikit
        let root = NavigationView { InspectorPlaygroundScreen(initialTab: tab) }.navigationViewStyle(.stack)
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .fullScreen
        topController()?.present(controller, animated: false)
    }

    private static func topController() -> UIViewController? {
        let window = activeScene?.windows.first { $0.isKeyWindow } ?? activeScene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private static func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        switch name {
        case "select":
            let pieces = argument.split(separator: "+").map(String.init)
            guard let identifier = pieces.first, let view = findView(identifier) else { return }
            DonkInspector.select(view: view, expandsPanel: pieces.contains("expanded"))
        case "outline":
            guard let view = findView(argument) else { return }
            DonkInspector.showsOutlinesWhileSelecting = true
            DonkInspector.select(view: view)
        case "measure":
            let ids = argument.split(separator: ",").map(String.init)
            guard ids.count == 2, let first = findView(ids[0]), let second = findView(ids[1]) else { return }
            DonkInspector.select(view: first)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                DonkInspector.measure(to: second)
            }
        case "frames":
            DonkInspector.start(.frames)
        case "grid":
            DonkInspector.start(.grid)
        case "eyedropper":
            DonkInspector.start(.colorPicker)
            guard let point = parsePoint(argument) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let hex = DonkInspector.sampleColor(at: point)
                print("DonkInspectorDemo sampled \(hex ?? "nil") at \(point)")
            }
        case "secure", "securewindow":
            let target = name == "securewindow" ? "demo.block.purple" : "demo.secureContainer"
            guard let container = findView(target), let window = container.window else { return }
            if name == "securewindow" {
                SecureWindowDemo.protect(window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let point = container.convert(CGPoint(x: container.bounds.midX, y: container.bounds.midY), to: nil)
                let hierarchy = hierarchyColor(of: window, at: point)
                DonkInspector.start(.colorPicker)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let hex = DonkInspector.sampleColor(at: point)
                    let superlayer = window.layer.superlayer.map { String(describing: type(of: $0)) } ?? "nil"
                    print("DonkInspectorDemo \(name): drawHierarchy=\(hierarchy) donk=\(hex ?? "nil") at \(point) windowSuperlayer=\(superlayer)")
                }
            }
        case "swiftui":
            DonkInspector.start(.select)
            guard let point = parsePoint(argument) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                DonkInspector.select(at: point, expandsPanel: true)
            }
        case "settings":
            showDebugger()
        case "verify":
            verify(modes: [.frames, .grid, .select, .colorPicker], report: [])
        default:
            break
        }
    }

    private static func verify(modes: [InspectorMode], report: [String]) {
        guard let mode = modes.first else {
            DonkInspector.stop()
            print("DonkInspectorVerify\n" + report.joined(separator: "\n"))
            return
        }
        DonkInspector.start(mode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            var lines = report
            let windows = activeScene?.windows ?? []
            let overlays = windows.filter { $0 is DonkWindowMarker && !$0.isHidden }
            let key = activeScene?.windows.first { $0.isKeyWindow }
            for overlay in overlays {
                let content = overlay.hitTest(CGPoint(x: 200, y: 330), with: nil)
                let toolbar = overlay.hitTest(CGPoint(x: overlay.bounds.midX, y: 87), with: nil)
                lines.append("\(mode.rawValue): level=\(overlay.windowLevel.rawValue) canBecomeKey=\(overlay.canBecomeKey) content=\(content.map { String(describing: type(of: $0)) } ?? "pass-through") toolbar=\(toolbar.map { String(describing: type(of: $0)) } ?? "pass-through")")
            }
            lines.append("\(mode.rawValue): key window is Donk = \(key.map { $0 is DonkWindowMarker } ?? false), activeMode=\(DonkInspector.activeMode?.rawValue ?? "nil")")
            verify(modes: Array(modes.dropFirst()), report: lines)
        }
    }

    private static func hierarchyColor(of window: UIWindow, at point: CGPoint) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return "nil" }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: -point.x, y: point.y - CGFloat(cgImage.height) + 1, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            return true
        }
        guard drawn else { return "nil" }
        return String(format: "#%02X%02X%02X a=%d", pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private static func parsePoint(_ text: String) -> CGPoint? {
        let values = text.split(separator: ",").compactMap { Double($0) }
        guard values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }

    private static func findView(_ identifier: String) -> UIView? {
        guard let scene = activeScene else { return nil }
        for window in scene.windows.reversed() where !(window is DonkWindowMarker) {
            if let match = find(identifier, in: window) { return match }
        }
        return nil
    }

    private static func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let match = find(identifier, in: subview) { return match }
        }
        return nil
    }
}

private struct DemoInspectorDebugger: View {
    var body: some View {
        DonkNavigationContainer {
            DonkInspector.makeRootView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            InspectorDemoSupport.hideDebugger()
                        }
                    }
                }
        }
    }
}
