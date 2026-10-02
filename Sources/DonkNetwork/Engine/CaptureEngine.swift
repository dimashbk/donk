import DonkCore
import Foundation

package struct CaptureEnvironment: Sendable {
    package var store: NetworkStore
    package var rules: RuleStore
    package var breakpoints: BreakpointCenter
    package var settings: NetworkSettingsStore
    package var isActive: @Sendable () -> Bool

    package init(
        store: NetworkStore = .shared,
        rules: RuleStore = .shared,
        breakpoints: BreakpointCenter = .shared,
        settings: NetworkSettingsStore = .shared,
        isActive: @escaping @Sendable () -> Bool = { DonkEnvironment.isActive }
    ) {
        self.store = store
        self.rules = rules
        self.breakpoints = breakpoints
        self.settings = settings
        self.isActive = isActive
    }

    package func resolution(method: String, url: String) -> RuleResolution {
        guard rules.hasActiveRules, isActive() else { return .empty }
        return rules.resolve(kind: .http, method: method, url: url)
    }
}

package final class CaptureEngine: @unchecked Sendable {
    package static let shared = CaptureEngine()

    private let lock = DonkLock()
    private var running = false
    private var registered = false
    private var currentConfiguration = NetworkCaptureConfiguration()
    private var currentEnvironment = CaptureEnvironment()
    private var testProtocolClasses: [AnyClass] = []

    package init() {}

    // MARK: - Lifecycle

    package var isRunning: Bool { lock.withLock { running } }

    package var configuration: NetworkCaptureConfiguration { lock.withLock { currentConfiguration } }

    package func start(_ configuration: NetworkCaptureConfiguration) {
        let (enable, disable): (Bool, Bool) = lock.withLock {
            currentConfiguration = configuration
            running = configuration.isEnabled
            if running, !registered {
                registered = true
                return (true, false)
            }
            if !running, registered {
                registered = false
                return (false, true)
            }
            return (false, false)
        }
        if configuration.isEnabled {
            SessionSwizzler.install()
            BodyStreamReader.removeStaleSpillFilesOnce()
        }
        if enable {
            URLProtocol.registerClass(DonkURLProtocol.self)
        }
        if disable {
            URLProtocol.unregisterClass(DonkURLProtocol.self)
        }
    }

    package func stop() {
        let unregister: Bool = lock.withLock {
            running = false
            defer { registered = false }
            return registered
        }
        if unregister {
            URLProtocol.unregisterClass(DonkURLProtocol.self)
        }
    }

    // MARK: - Environment

    package var environment: CaptureEnvironment {
        get { lock.withLock { currentEnvironment } }
        set { lock.withLock { currentEnvironment = newValue } }
    }

    package var innerProtocolClasses: [AnyClass] {
        get { lock.withLock { testProtocolClasses } }
        set {
            lock.withLock { testProtocolClasses = newValue }
            SessionContextRegistry.shared.resetInnerSessions()
        }
    }

    // MARK: - Gate

    package func shouldIntercept(_ request: URLRequest, passesThroughUnlessRuled: Bool = false) -> Bool {
        let (isRunning, bypassHosts, environment) = lock.withLock { (running, currentConfiguration.bypassHosts, currentEnvironment) }
        guard isRunning else { return false }
        guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if Self.isMarked(DonkURLProtocol.handledKey, in: request) || Self.isMarked(DonkEnvironment.internalRequestKey, in: request) {
            return false
        }
        guard environment.store.isCaptureEnabled else { return false }
        if let upgrade = request.value(forHTTPHeaderField: "Upgrade"), upgrade.range(of: "websocket", options: .caseInsensitive) != nil {
            return false
        }
        let host = url.host
        if HostPattern.matchesAny(host, patterns: bypassHosts) { return false }
        let settingsBypass = environment.settings.settings.bypassHosts
        if HostPattern.matchesAny(host, patterns: settingsBypass) { return false }
        guard passesThroughUnlessRuled else { return true }
        let parts = RequestParts(request: request, body: .none)
        return !environment.resolution(method: parts.method, url: parts.urlString).isEmpty
    }

    private static func isMarked(_ key: String, in request: URLRequest) -> Bool {
        guard let value = URLProtocol.property(forKey: key, in: request) else { return false }
        if let flag = value as? Bool { return flag }
        return true
    }
}
