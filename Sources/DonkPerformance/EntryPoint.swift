import Combine
import DonkCore
import DonkUI
import SwiftUI

public struct PerformanceConfiguration: Sendable {
    public var alertsEnabled = true

    public init() {}
}

public enum DonkPerformance {
    public static func start(_ configuration: PerformanceConfiguration) {
        PerformanceMonitor.shared.start(configuration)
    }

    public static func stop() {
        PerformanceMonitor.shared.stop()
    }

    @MainActor public static var isHUDVisible: Bool {
        get { PerformanceMonitor.shared.preferences.value.isHUDVisible }
        set {
            PerformanceMonitor.shared.preferences.update { $0.isHUDVisible = newValue }
            HUDController.shared.setVisible(newValue && PerformanceMonitor.shared.isRunning)
        }
    }

    @MainActor public static var hudStaysAboveKeyboard: Bool {
        get { HUDController.shared.staysAboveKeyboard }
        set { HUDController.shared.setStaysAboveKeyboard(newValue) }
    }

    @MainActor public static func makeRootView() -> AnyView {
        AnyView(PerformanceDashboardView().donkTheme())
    }

    @MainActor public static func makeDashboardSparkline() -> AnyView {
        AnyView(PerformanceSparklineView())
    }

    // MARK: - Additional API

    public static var isRunning: Bool {
        PerformanceMonitor.shared.isRunning
    }

    public static var alertsEnabled: Bool {
        get { PerformanceMonitor.shared.alertsEnabled }
        set { PerformanceMonitor.shared.alertsEnabled = newValue }
    }

    public static var alertSettings: PerformanceAlertSettings {
        get { PerformanceMonitor.shared.preferences.value.alerts }
        set { PerformanceMonitor.shared.updateAlertSettings(newValue) }
    }

    public static var samplingRate: PerformanceSamplingRate {
        get { PerformanceMonitor.shared.preferences.value.samplingRate }
        set { PerformanceMonitor.shared.setSamplingRate(newValue) }
    }

    @MainActor public static var prefersHighRefreshRate: Bool {
        get { PerformanceMonitor.shared.preferences.value.prefersHighRefreshRate }
        set { PerformanceMonitor.shared.setPrefersHighRefreshRate(newValue) }
    }

    public static var latestSample: PerformanceSample? {
        PerformanceMonitor.shared.latestSample
    }

    public static var samples: AnyPublisher<PerformanceSample, Never> {
        PerformanceMonitor.shared.updates
            .compactMap { update in
                if case let .sample(sample) = update { return sample }
                return nil
            }
            .eraseToAnyPublisher()
    }

    public static var recentEvents: [PerformanceEvent] {
        PerformanceMonitor.shared.recentEvents
    }

    public static func resetHistory() {
        PerformanceMonitor.shared.resetHistory()
    }

    @MainActor public static func makeEventDetailView(_ event: PerformanceEvent) -> AnyView {
        AnyView(PerformanceEventDetailView(event: event).donkTheme())
    }
}
