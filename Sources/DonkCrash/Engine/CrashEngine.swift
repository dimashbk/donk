import DonkCore
import DonkCrashC
import Foundation
import os
import UIKit

struct CrashPaths: Sendable {
    let root: URL
    let settingsDirectory: URL

    var raw: URL { root.appendingPathComponent("Raw", isDirectory: true) }
    var inbox: URL { raw.appendingPathComponent("Inbox", isDirectory: true) }
    var quarantine: URL { raw.appendingPathComponent("Quarantine", isDirectory: true) }
    var pending: URL { raw.appendingPathComponent("pending.donkcrash", isDirectory: false) }
    var exception: URL { raw.appendingPathComponent("exception.json", isDirectory: false) }
    var launch: URL { raw.appendingPathComponent("launch.json", isDirectory: false) }
    var session: URL { raw.appendingPathComponent("session.json", isDirectory: false) }

    static let standard = CrashPaths(
        root: DonkPersistence.directory.appendingPathComponent("Crashes", isDirectory: true),
        settingsDirectory: DonkPersistence.directory
    )

    enum Slot: String, CaseIterable {
        case pending = "signal"
        case exception
        case launch
        case session
    }

    func url(for slot: Slot) -> URL {
        switch slot {
        case .pending: return pending
        case .exception: return exception
        case .launch: return launch
        case .session: return session
        }
    }
}

final class CrashEngine: @unchecked Sendable {
    static let shared = CrashEngine(paths: .standard)
    static let parseAttemptLimit = 3
    static let quarantineLimit = 10

    let paths: CrashPaths
    let store: CrashReportStore
    let settings: CrashSettingsStore
    let queue = DispatchQueue(label: "dev.donk.crash", qos: .utility)
    private let lock = DonkLock()
    private var installed = false
    private var processing = false
    private var sessionActive = false
    private var recordsOpen = true
    private var afterAnotherReporter = false
    private var observers: [NSObjectProtocol] = []
    private var metricKitCollector: AnyObject?
    private let currentLaunch: LaunchInfo
    private let processingGroup = DispatchGroup()
    private let log = OSLog(subsystem: "io.github.donk", category: "crash")

    init(paths: CrashPaths) {
        self.paths = paths
        store = CrashReportStore(directory: paths.root)
        settings = CrashSettingsStore(directory: paths.settingsDirectory)
        currentLaunch = LaunchInfo.current()
    }

    var isInstalled: Bool {
        lock.withLock { installed }
    }

    var isProcessing: Bool {
        lock.withLock { processing }
    }

    var installedAfterAnotherReporter: Bool {
        lock.withLock { afterAnotherReporter }
    }

    var isRecording: Bool {
        lock.withLock { installed && recordsOpen }
    }

    static let installOrderWarning = "donk was installed after another crash reporter — hardware crashes won't be captured; call Donk.installCrashReporter() before FirebaseApp.configure()"

    // MARK: - Install

    func install(handlesSignals: Bool = true, observesLifecycle: Bool = true, subscribesToMetricKit: Bool = true) {
        let shouldInstall: Bool = lock.withLock {
            guard !installed else { return false }
            installed = true
            processing = true
            return true
        }
        guard shouldInstall else { return }

        DonkPersistence.createDirectory(paths.inbox)
        let batch = moveToInbox()

        if let data = CrashJSON.encode(currentLaunch) {
            try? data.write(to: paths.launch, options: .atomic)
        }

        if handlesSignals {
            let result = donk_crash_install(paths.pending.path, paths.exception.path)
            let afterOther = donk_crash_installed_after_other_handler() == 1
            lock.withLock {
                recordsOpen = result == 0
                afterAnotherReporter = afterOther
            }
            if afterOther {
                os_log("%{public}@", log: log, type: .fault, Self.installOrderWarning)
            }
            if result != 0 {
                os_log("Crash record files could not be opened; signals are still chained and the files are reopened when protected data becomes available", log: log, type: .error)
            }
            observeRecordRetry()
            CrashEngine.installMainThreadAlternateStack()
            CrashExceptionHandler.install(engine: self)
        }

        if observesLifecycle {
            startSessionTracking()
        }

        processingGroup.enter()
        queue.async { [self] in
            processInbox(preferredBatch: batch)
            lock.withLock { processing = false }
            processingGroup.leave()
            if subscribesToMetricKit {
                startMetricKit()
            }
        }
    }

    static func installMainThreadAlternateStack() {
        if Thread.isMainThread {
            donk_crash_install_alternate_stack()
        } else {
            DispatchQueue.main.async {
                donk_crash_install_alternate_stack()
            }
        }
    }

    private func observeRecordRetry() {
        guard lock.withLock({ !recordsOpen }) else { return }
        let center = NotificationCenter.default
        let names = [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.reopenRecords()
            }
        }
        lock.withLock { observers.append(contentsOf: tokens) }
    }

    @discardableResult
    func reopenRecords() -> Bool {
        guard lock.withLock({ installed && !recordsOpen }) else { return true }
        try? FileManager.default.createDirectory(at: paths.raw, withIntermediateDirectories: true)
        let opened = donk_crash_open_records(paths.pending.path, paths.exception.path) == 0
        lock.withLock { recordsOpen = opened }
        return opened
    }

    func waitForProcessing(timeout: TimeInterval) -> Bool {
        processingGroup.wait(timeout: .now() + timeout) == .success
    }

    @discardableResult
    func moveToInbox() -> String? {
        let fileManager = FileManager.default
        let batch = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        var moved = false
        for slot in CrashPaths.Slot.allCases {
            let source = paths.url(for: slot)
            guard let attributes = try? fileManager.attributesOfItem(atPath: source.path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size == 0 {
                try? fileManager.removeItem(at: source)
                continue
            }
            let destination = paths.inbox.appendingPathComponent("\(batch).\(slot.rawValue)", isDirectory: false)
            if rename(source.path, destination.path) == 0 {
                moved = true
            }
        }
        return moved ? batch : nil
    }

    // MARK: - Processing

    typealias FileReader = (URL) throws -> Data

    func processInbox(preferredBatch: String? = nil, reader: FileReader = { try Data(contentsOf: $0) }) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil)) ?? []
        var groups: [String: [CrashPaths.Slot: URL]] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard let dot = name.lastIndex(of: ".") else {
                try? fileManager.removeItem(at: file)
                continue
            }
            let batch = String(name[..<dot])
            guard let slot = CrashPaths.Slot(rawValue: String(name[name.index(after: dot)...])) else {
                try? fileManager.removeItem(at: file)
                continue
            }
            groups[batch, default: [:]][slot] = file
        }
        guard !groups.isEmpty else {
            pruneAttempts(keeping: [])
            return
        }

        let symbolicator = Symbolicator()
        let builder = CrashReportBuilder(symbolicator: symbolicator, fallbackLaunch: currentLaunch)
        let detectsUnclean = settings.settings.detectsUncleanExits
        var reports: [CrashReport] = []
        var finished: [String] = []
        var unparsable: [String] = []
        for batch in groups.keys.sorted() {
            guard let group = groups[batch], let data = Self.read(group, reader: reader) else { continue }
            let raw = data[.pending].flatMap(RawCrashParser.parse)
            let exception = data[.exception].flatMap(ExceptionRecord.decode)
            let launch = data[.launch].flatMap { CrashJSON.decode(LaunchInfo.self, from: $0) }
            let marker = data[.session].flatMap { CrashJSON.decode(SessionMarker.self, from: $0) }
            let pendingFailed = data[.pending].map { !$0.isEmpty && raw == nil } ?? false
            let exceptionFailed = data[.exception].map { !$0.isEmpty && exception == nil } ?? false
            if let report = builder.build(raw: raw, exception: exception, launch: launch) {
                reports.append(report)
                finished.append(batch)
            } else if pendingFailed || exceptionFailed {
                unparsable.append(batch)
            } else {
                if let report = UncleanExitDetector.report(marker: marker, hasCrash: false, isEnabled: detectsUnclean, current: currentLaunch, launch: launch) {
                    reports.append(report)
                }
                finished.append(batch)
            }
        }
        store.add(reports)
        for batch in finished {
            groups[batch]?.values.forEach { try? fileManager.removeItem(at: $0) }
        }
        let quarantined = recordParseFailures(unparsable)
        for batch in quarantined {
            if let group = groups[batch] {
                quarantine(Array(group.values))
            }
        }
        let remaining = Set(groups.keys).subtracting(finished).subtracting(quarantined)
        pruneAttempts(keeping: remaining)
    }

    static func read(_ group: [CrashPaths.Slot: URL], reader: FileReader) -> [CrashPaths.Slot: Data]? {
        var result: [CrashPaths.Slot: Data] = [:]
        for (slot, url) in group {
            guard let data = try? reader(url) else { return nil }
            result[slot] = data
        }
        return result
    }

    private func recordParseFailures(_ batches: [String]) -> Set<String> {
        guard !batches.isEmpty else { return [] }
        return settings.update { value in
            var exhausted = Set<String>()
            for batch in batches {
                let attempts = (value.inboxAttempts[batch] ?? 0) + 1
                if attempts > Self.parseAttemptLimit {
                    exhausted.insert(batch)
                    value.inboxAttempts[batch] = nil
                } else {
                    value.inboxAttempts[batch] = attempts
                }
            }
            return exhausted
        }
    }

    private func pruneAttempts(keeping batches: Set<String>) {
        guard !settings.settings.inboxAttempts.isEmpty else { return }
        settings.update { value in
            value.inboxAttempts = value.inboxAttempts.filter { batches.contains($0.key) }
        }
    }

    private func quarantine(_ files: [URL]) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: paths.quarantine, withIntermediateDirectories: true)
        for file in files {
            let destination = paths.quarantine.appendingPathComponent(file.lastPathComponent, isDirectory: false)
            try? fileManager.removeItem(at: destination)
            if (try? fileManager.moveItem(at: file, to: destination)) == nil {
                try? fileManager.removeItem(at: file)
            }
        }
        os_log("Quarantined an unreadable crash record batch after %d attempts", log: log, type: .error, Self.parseAttemptLimit + 1)
        let names = ((try? fileManager.contentsOfDirectory(atPath: paths.quarantine.path)) ?? []).sorted()
        let batches = Array(Set(names.compactMap { $0.split(separator: ".").first.map(String.init) })).sorted()
        guard batches.count > Self.quarantineLimit else { return }
        let stale = Set(batches.prefix(batches.count - Self.quarantineLimit))
        for name in names where stale.contains(String(name.split(separator: ".").first ?? "")) {
            try? fileManager.removeItem(at: paths.quarantine.appendingPathComponent(name))
        }
    }

    // MARK: - Exceptions

    func writeException(_ exception: NSException) {
        let record = ExceptionRecord(exception: exception, images: exceptionImages(for: exception))
        guard let data = record.encoded() else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = donk_crash_write_exception(base, buffer.count)
        }
    }

    private func exceptionImages(for exception: NSException) -> [RawImage] {
        let images = Symbolicator.currentRawImages()
        let index = ImageIndex(images: images, currentBundlePath: Bundle.main.bundlePath)
        var wanted = Set<UInt64>()
        for address in exception.callStackReturnAddresses.map(\.uint64Value) {
            if let image = index.image(containing: address) {
                wanted.insert(image.loadAddress)
            }
        }
        return images.filter { wanted.contains($0.loadAddress) || index.isApp($0) }
    }

    // MARK: - Session

    private func startSessionTracking() {
        donk_crash_track_session_marker(paths.session.path)
        let center = NotificationCenter.default
        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sessionBecameActive()
        }
        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sessionEnded()
        }
        let terminate = center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sessionEnded()
        }
        lock.withLock { observers.append(contentsOf: [active, background, terminate]) }
        DispatchQueue.main.async { [weak self] in
            if UIApplication.shared.applicationState == .active {
                self?.sessionBecameActive()
            }
        }
    }

    func sessionBecameActive() {
        lock.withLock { sessionActive = true }
        writeSessionMarker()
    }

    func sessionEnded() {
        lock.withLock { sessionActive = false }
        try? FileManager.default.removeItem(at: paths.session)
    }

    private func writeSessionMarker() {
        guard settings.settings.detectsUncleanExits, lock.withLock({ sessionActive }) else { return }
        let marker = SessionMarker(
            version: currentLaunch.version,
            build: currentLaunch.build,
            osVersion: currentLaunch.osVersion,
            launchDate: currentLaunch.launchDate,
            activeDate: Date(),
            processID: currentLaunch.processID,
            debuggerAttached: donk_crash_debugger_attached() == 1
        )
        if let data = CrashJSON.encode(marker) {
            try? data.write(to: paths.session, options: .atomic)
        }
    }

    var detectsUncleanExits: Bool {
        get { settings.settings.detectsUncleanExits }
        set {
            settings.update { $0.detectsUncleanExits = newValue }
            if newValue {
                writeSessionMarker()
            } else {
                try? FileManager.default.removeItem(at: paths.session)
            }
        }
    }

    // MARK: - MetricKit

    private func startMetricKit() {
        #if canImport(MetricKit)
        let collector = MetricKitCollector { [weak self] diagnostics in
            self?.queue.async { self?.ingest(diagnostics) }
        }
        lock.withLock { metricKitCollector = collector }
        collector.start()
        #endif
    }

    func ingest(_ diagnostics: [MetricKitDiagnostic]) {
        let fresh: [MetricKitDiagnostic] = settings.update { value in
            var seen = Set(value.seenMetricKitPayloads)
            var accepted: [MetricKitDiagnostic] = []
            for diagnostic in diagnostics where !seen.contains(diagnostic.signature) {
                seen.insert(diagnostic.signature)
                value.seenMetricKitPayloads.append(diagnostic.signature)
                accepted.append(diagnostic)
            }
            if value.seenMetricKitPayloads.count > CrashSettings.metricKitHistoryLimit {
                value.seenMetricKitPayloads.removeFirst(value.seenMetricKitPayloads.count - CrashSettings.metricKitHistoryLimit)
            }
            return accepted
        }
        guard !fresh.isEmpty else { return }
        let symbolicator = Symbolicator()
        store.add(fresh.map { MetricKitConverter.report(from: $0, symbolicator: symbolicator, current: currentLaunch) })
    }
}

// MARK: - NSException

enum CrashExceptionHandler {
    private static let lock = DonkLock()
    private static var installed = false
    private static var previous: (@convention(c) (NSException) -> Void)?
    private static weak var engine: CrashEngine?

    static func install(engine: CrashEngine) {
        lock.withLock {
            self.engine = engine
            guard !installed else { return }
            installed = true
            previous = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                CrashExceptionHandler.handle(exception)
            }
        }
    }

    static func handle(_ exception: NSException) {
        let (engine, previous) = lock.withLock { (self.engine, self.previous) }
        engine?.writeException(exception)
        previous?(exception)
    }
}
