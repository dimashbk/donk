import Combine
import DonkCore
import DonkNetwork
import DonkPerformance
import DonkPush
import DonkStorage
import DonkWebView
import Foundation

final class DonkEngine: @unchecked Sendable {
    static let shared = DonkEngine()

    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var running = false
    private var generation = 0
    private var configuration = DonkConfiguration()
    private var cancellables: [AnyCancellable] = []
    private var startedWebViews = false
    private var startedPerformance = false
    private var startedPush = false
    private var appliedBypassHosts: [String] = []

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var currentConfiguration: DonkConfiguration {
        stateLock.lock()
        defer { stateLock.unlock() }
        return configuration
    }

    func isCurrent(_ token: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && generation == token
    }

    func start(_ configuration: DonkConfiguration) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isRunning else { return }

        if let redaction = configuration.redaction {
            NetworkSettingsStore.shared.update { $0.redaction = redaction }
        }
        let preferences = DonkPreferencesStore.shared.value
        let settings = NetworkSettingsStore.shared.settings
        NetworkStore.shared.configure(with: settings)
        DonkLiveSettings.apply(preferences)

        let capture = Self.captureConfiguration(configuration.network, settings: settings)
        DonkNetworkCapture.start(capture)
        if configuration.captureWebViews {
            DonkWebViewCapture.start(automatic: true)
        }
        let tools = configuration.tools
        if tools.contains(.performance) {
            DonkPerformance.start(configuration.performance)
        }
        if tools.contains(.push) {
            DonkPush.start(configuration.push)
        }
        if tools.contains(.storage) {
            DonkStorage.configure(configuration.storage)
        }

        let settingsSubscription = NetworkSettingsStore.shared.changes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] settings in self?.apply(settings) }
        let preferencesSubscription = DonkPreferencesStore.shared.changes
            .dropFirst()
            .sink { DonkLiveSettings.apply($0) }

        stateLock.lock()
        running = true
        generation += 1
        let token = generation
        self.configuration = configuration
        startedWebViews = configuration.captureWebViews
        startedPerformance = tools.contains(.performance)
        startedPush = tools.contains(.push)
        appliedBypassHosts = capture.bypassHosts
        cancellables = [settingsSubscription, preferencesSubscription]
        stateLock.unlock()

        DonkEnvironment.setActive(true)
        DonkMainQueue.run {
            DonkRuntime.shared.start(configuration, token: token)
        }
    }

    func stop() {
        operationLock.lock()
        defer { operationLock.unlock() }

        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        generation += 1
        let subscriptions = cancellables
        cancellables = []
        let stopWebViews = startedWebViews
        let stopPerformance = startedPerformance
        let stopPush = startedPush
        startedWebViews = false
        startedPerformance = false
        startedPush = false
        appliedBypassHosts = []
        stateLock.unlock()

        DonkEnvironment.setActive(false)
        subscriptions.forEach { $0.cancel() }
        DonkNetworkCapture.stop()
        if stopWebViews {
            DonkWebViewCapture.stop()
        }
        if stopPerformance {
            DonkPerformance.stop()
        }
        if stopPush {
            DonkPush.stop()
        }

        DonkMainQueue.run {
            DonkRuntime.shared.stop()
        }
    }

    // MARK: - Settings sync

    private func apply(_ settings: NetworkSettings) {
        NetworkStore.shared.configure(with: settings)
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        let capture = Self.captureConfiguration(configuration.network, settings: settings)
        let changed = capture.bypassHosts != appliedBypassHosts
        if changed {
            appliedBypassHosts = capture.bypassHosts
        }
        stateLock.unlock()
        if changed {
            DonkNetworkCapture.start(capture)
        }
    }

    static func captureConfiguration(_ base: NetworkCaptureConfiguration, settings: NetworkSettings) -> NetworkCaptureConfiguration {
        var result = base
        var seen = Set<String>()
        result.bypassHosts = (base.bypassHosts + settings.bypassHosts).filter { pattern in
            let key = pattern.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
        return result
    }
}

// MARK: - Main hop

enum DonkMainQueue {
    static func run(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { work() }
        }
    }
}
