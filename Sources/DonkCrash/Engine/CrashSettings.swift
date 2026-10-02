import DonkCore
import Foundation

struct CrashSettings: Codable, Equatable, Sendable {
    var detectsUncleanExits = true
    var seenMetricKitPayloads: [String] = []
    var inboxAttempts: [String: Int] = [:]

    static let metricKitHistoryLimit = 256

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detectsUncleanExits = try container.decodeIfPresent(Bool.self, forKey: .detectsUncleanExits) ?? true
        seenMetricKitPayloads = try container.decodeIfPresent([String].self, forKey: .seenMetricKitPayloads) ?? []
        inboxAttempts = try container.decodeIfPresent([String: Int].self, forKey: .inboxAttempts) ?? [:]
    }
}

final class CrashSettingsStore: @unchecked Sendable {
    private let directory: URL
    private let fileName: String
    private let lock = DonkLock()
    private var cached: CrashSettings?

    init(directory: URL, fileName: String = "crash-settings.json") {
        self.directory = directory
        self.fileName = fileName
    }

    var settings: CrashSettings {
        lock.withLock { loadedLocked() }
    }

    @discardableResult
    func update<T>(_ transform: (inout CrashSettings) -> T) -> T {
        lock.withLock {
            var value = loadedLocked()
            let result = transform(&value)
            if value != cached {
                cached = value
                DonkPersistence.save(value, to: fileName, in: directory)
            }
            return result
        }
    }

    private func loadedLocked() -> CrashSettings {
        if let cached {
            return cached
        }
        let value = DonkPersistence.load(CrashSettings.self, from: fileName, in: directory) ?? CrashSettings()
        cached = value
        return value
    }
}

enum UncleanExitDetector {
    static func report(marker: SessionMarker?, hasCrash: Bool, isEnabled: Bool, current: LaunchInfo, launch: LaunchInfo?) -> CrashReport? {
        guard isEnabled, let marker, !hasCrash, marker.debuggerAttached != true else { return nil }
        guard marker.version == current.version, marker.build == current.build, marker.osVersion == current.osVersion else {
            return nil
        }
        let info = launch ?? current
        let details = [
            CrashDetail("Launched", DonkDateText.full(marker.launchDate)),
            CrashDetail("Last foreground", DonkDateText.full(marker.activeDate)),
            CrashDetail("Process ID", String(marker.processID)),
            CrashDetail("Hint", "The app stopped while in the foreground without a crash record. Common causes: memory pressure (jetsam), the watchdog killing a hung main thread, a stop from Xcode or simctl, or a crash Donk could not record."),
        ]
        return CrashReport(
            date: marker.activeDate,
            kind: .uncleanExit,
            appName: info.appName,
            bundleID: info.bundleID,
            appVersion: marker.version,
            appBuild: marker.build,
            osVersion: marker.osVersion,
            deviceModel: info.deviceModel,
            architecture: CrashArchitecture.current,
            processID: marker.processID,
            launchDate: marker.launchDate,
            details: details
        )
    }
}

enum DonkDateText {
    static func full(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
