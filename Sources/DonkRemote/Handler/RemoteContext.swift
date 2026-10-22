import CoreGraphics
import DonkCore
import DonkCrash
import Foundation

protocol RemoteCrashProvider: Sendable {
    var isInstalled: Bool { get }
    func reports() -> [CrashReport]
    func text(for report: CrashReport) -> String
}

struct RemoteTreeOptions: Equatable, Sendable {
    var maxDepth = 40
    var includeHidden = false
    var maxNodes = 3000
}

protocol RemoteUIProvider: Sendable {
    @MainActor func hasForegroundScene() -> Bool
    @MainActor func tree(_ options: RemoteTreeOptions) throws -> JSONValue
    @MainActor func screenshot(scale: CGFloat) throws -> CGImage
}

struct RemoteContext: @unchecked Sendable {
    var identity: RemoteIdentity
    var store: NetworkStore
    var settings: NetworkSettingsStore
    var rules: RuleStore
    var crashes: RemoteCrashProvider?
    var ui: RemoteUIProvider?
    var redacts = true
    var redaction: RedactionPolicy?
    var launchDate: Date = ProcessLaunch.date
    var now: @Sendable () -> Date = { Date() }
    var maxFrameBytes = 16 * 1024 * 1024

    var policy: RedactionPolicy? {
        guard redacts else { return nil }
        return redaction ?? settings.settings.redaction
    }
}

// MARK: - Live crashes

struct LiveCrashProvider: RemoteCrashProvider {
    var isInstalled: Bool { DonkCrash.isInstalled }

    func reports() -> [CrashReport] {
        DonkCrash.reports()
    }

    func text(for report: CrashReport) -> String {
        DonkCrash.textReport(for: report)
    }
}
