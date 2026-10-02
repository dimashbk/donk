@_exported import DonkCore
@_exported import DonkCrash
@_exported import DonkInspector
@_exported import DonkJSON
@_exported import DonkNetwork
@_exported import DonkNetworkUI
@_exported import DonkPerformance
@_exported import DonkPush
@_exported import DonkStorage
@_exported import DonkWebView
import Foundation

public struct DonkConfiguration: Sendable {
    public var network = NetworkCaptureConfiguration()
    public var captureWebViews = true
    public var performance = PerformanceConfiguration()
    public var push = PushConfiguration()
    public var storage = StorageConfiguration()
    public var showsBubble = true
    public var opensOnShake = true
    public var redaction: RedactionPolicy?
    public var tools: Set<DonkTool> = Set(DonkTool.allCases)

    public init() {}
}

public enum DonkTool: String, CaseIterable, Sendable {
    case network, rules, performance, inspector, push, storage, crashes, settings
}

public enum Donk {
    public static let version = DonkEnvironment.version

    public static func start(_ configuration: DonkConfiguration = .init()) {
        DonkEngine.shared.start(configuration)
    }

    public static func stop() {
        DonkEngine.shared.stop()
    }

    public static var isRunning: Bool {
        DonkEngine.shared.isRunning
    }

    public static func installCrashReporter() {
        DonkCrash.install()
    }

    @MainActor public static func show() {
        DonkRuntime.shared.show(nil)
    }

    @MainActor public static func show(_ tool: DonkTool) {
        DonkRuntime.shared.show(tool)
    }

    @MainActor public static func hide() {
        DonkRuntime.shared.hide()
    }

    @MainActor public static func toggle() {
        DonkRuntime.shared.toggle()
    }

    @MainActor public static func showQuickActions() {
        DonkRuntime.shared.showQuickActions()
    }
}
