import DonkCore
import DonkCrash
import Foundation

enum RemoteCrashes {
    static let defaultLimit = 20
    static let limitRange = 1...200

    static func list(_ params: RemoteParams, context: RemoteContext) throws -> JSONValue {
        let provider = try installed(context)
        let limit = try params.clamped("limit", default: defaultLimit, range: limitRange)
        let reports = provider.reports().sorted(by: newestFirst).prefix(limit)
        var result = RemoteObject()
        result.set("reports", .array(reports.map { summary($0).value }))
        return result.value
    }

    static func get(_ params: RemoteParams, context: RemoteContext) throws -> JSONValue {
        let provider = try installed(context)
        guard let input = try params.string("id") else {
            throw RemoteError.invalidParams("id is required")
        }
        let report = try RemoteIDResolver.resolve(input, in: provider.reports(), noun: "crash report", id: \.id)
        var value = summary(report)
        value.set("text", provider.text(for: report))
        var result = RemoteObject()
        result.set("report", value.value)
        return result.value
    }

    static func summary(_ report: CrashReport) -> RemoteObject {
        var object = RemoteObject()
        object.set("id", report.id.uuidString)
        object.set("date", date: report.date)
        object.set("kind", report.kind.rawValue)
        object.set("title", report.title)
        object.setNonEmpty("reason", report.subtitle?.replacingOccurrences(of: "\n", with: " "))
        object.set("appVersion", report.appVersion)
        object.set("appBuild", report.appBuild)
        object.set("osVersion", report.osVersion)
        return object
    }

    private static func installed(_ context: RemoteContext) throws -> RemoteCrashProvider {
        guard let provider = context.crashes, provider.isInstalled else {
            throw RemoteError.unavailable("crash reporter is not installed (call Donk.installCrashReporter())")
        }
        return provider
    }

    private static func newestFirst(_ lhs: CrashReport, _ rhs: CrashReport) -> Bool {
        lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date > rhs.date
    }
}
