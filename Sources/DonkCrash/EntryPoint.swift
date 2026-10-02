import Combine
import DonkCore
import Foundation
import SwiftUI

public enum DonkCrash {
    public static func install() {
        CrashEngine.shared.install()
    }

    public static var isInstalled: Bool { CrashEngine.shared.isInstalled }

    public static var installedAfterAnotherReporter: Bool { CrashEngine.shared.installedAfterAnotherReporter }

    public static func reportCount() -> Int {
        CrashEngine.shared.store.count
    }

    @MainActor public static func makeRootView() -> AnyView {
        AnyView(CrashListView(engine: .shared))
    }

    public static func reports() -> [CrashReport] {
        CrashEngine.shared.store.all()
    }

    public static func delete(_ report: CrashReport) {
        CrashEngine.shared.store.delete([report.id])
    }

    public static func delete(_ ids: Set<UUID>) {
        CrashEngine.shared.store.delete(ids)
    }

    public static func deleteAll() {
        CrashEngine.shared.store.deleteAll()
    }

    public static var detectsUncleanExits: Bool {
        get { CrashEngine.shared.detectsUncleanExits }
        set { CrashEngine.shared.detectsUncleanExits = newValue }
    }

    public static var reportsDidChange: AnyPublisher<[CrashReport], Never> {
        CrashEngine.shared.store.changes
    }

    public static func textReport(for report: CrashReport) -> String {
        CrashTextFormatter.text(for: report)
    }

    public static func jsonReport(for report: CrashReport) -> Data? {
        CrashExport.json(for: report)
    }

    @MainActor public static func makeDetailView(for report: CrashReport) -> AnyView {
        AnyView(CrashDetailView(report: report, onDelete: nil))
    }
}

enum CrashExport {
    static func json(for report: CrashReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(report)
    }

    static func fileBaseName(for report: CrashReport) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let app = report.appName.replacingOccurrences(of: " ", with: "-")
        return "\(app.isEmpty ? "App" : app)-\(formatter.string(from: report.date))"
    }
}
