import DonkCore
import DonkCrash
import Foundation
import XCTest
@testable import DonkRemote

final class RemoteCrashTests: XCTestCase {
    private let older = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!
    private let newer = UUID(uuidString: "C0000000-1111-4000-8000-000000000002")!
    private let signal = UUID(uuidString: "D0000000-0000-4000-8000-000000000003")!

    private func fixture(installed: Bool = true) -> RemoteFixture {
        var fixture = RemoteFixture()
        fixture.crashes = FakeCrashProvider(isInstalled: installed, reports: [
            sampleCrash(id: older, date: Date(timeIntervalSince1970: 1_800_000_000)),
            sampleCrash(id: newer, date: Date(timeIntervalSince1970: 1_800_000_100), reason: nil),
            CrashReport(
                id: signal,
                date: Date(timeIntervalSince1970: 1_800_000_050.5),
                kind: .signal,
                appName: "Freedom Business",
                bundleID: "kz.globerce.fb",
                appVersion: "1.16.0",
                appBuild: "1200",
                osVersion: "26.0",
                deviceModel: "iPhone17,1",
                signal: CrashReport.SignalInfo(number: 11, name: "SIGSEGV", code: 2, codeName: "SEGV_ACCERR", faultAddress: 0x10, machException: "EXC_BAD_ACCESS")
            ),
        ])
        return fixture
    }

    func testListMapsReportsNewestFirst() async throws {
        let result = try await call(fixture().handler, "crashes.list")
        let reports = try XCTUnwrap(result["reports"]?.array)
        XCTAssertEqual(reports.compactMap { $0["id"]?.string }, [newer, signal, older].map(\.uuidString))
        let signalReport = reports[1]
        XCTAssertEqual(signalReport.keys, ["id", "date", "kind", "title", "reason", "appVersion", "appBuild", "osVersion"])
        XCTAssertEqual(signalReport["date"]?.string, "2027-01-15T08:00:50.500Z")
        XCTAssertEqual(signalReport["kind"]?.string, "signal")
        XCTAssertEqual(signalReport["title"]?.string, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(signalReport["reason"]?.string, "SEGV_ACCERR")
        XCTAssertEqual(signalReport["appVersion"]?.string, "1.16.0")
        XCTAssertEqual(signalReport["appBuild"]?.string, "1200")
        XCTAssertEqual(signalReport["osVersion"]?.string, "26.0")
        XCTAssertEqual(reports[2]["title"]?.string, "NSRangeException")
        XCTAssertEqual(reports[2]["reason"]?.string, "index 3 beyond bounds [0 .. 2]")
        XCTAssertNil(reports[0]["reason"])
    }

    func testListLimit() async throws {
        let handler = fixture().handler
        let one = try await call(handler, "crashes.list", #"{"limit":1}"#)
        XCTAssertEqual(one["reports"]?.array?.count, 1)
        let clamped = try await call(handler, "crashes.list", #"{"limit":0}"#)
        XCTAssertEqual(clamped["reports"]?.array?.count, 1)
        let many = try await call(handler, "crashes.list", #"{"limit":1000}"#)
        XCTAssertEqual(many["reports"]?.array?.count, 3)
    }

    func testGetReturnsFullText() async throws {
        let result = try await call(fixture().handler, "crashes.get", #"{"id":"d0000000"}"#)
        let report = try XCTUnwrap(result["report"])
        XCTAssertEqual(report.keys, ["id", "date", "kind", "title", "reason", "appVersion", "appBuild", "osVersion", "text"])
        XCTAssertEqual(report["id"]?.string, signal.uuidString)
        XCTAssertEqual(report["text"]?.string, "TEXT \(signal.uuidString)")
    }

    func testGetResolvesPrefixes() async {
        let handler = fixture().handler
        let ambiguous = await callError(handler, "crashes.get", #"{"id":"c0000000"}"#)
        XCTAssertEqual(ambiguous?.code, -32002)
        let missing = await callError(handler, "crashes.get", #"{"id":"e0000000"}"#)
        XCTAssertEqual(missing?.code, -32000)
        let noID = await callError(handler, "crashes.get")
        XCTAssertEqual(noID?.code, -32602)
    }

    func testUnavailableWhenNotInstalled() async {
        let handler = fixture(installed: false).handler
        let list = await callError(handler, "crashes.list")
        XCTAssertEqual(list?.code, -32001)
        let get = await callError(handler, "crashes.get", #"{"id":"\#(older.uuidString)"}"#)
        XCTAssertEqual(get?.code, -32001)
        let none = await callError(RemoteFixture().handler, "crashes.list")
        XCTAssertEqual(none?.code, -32001)
    }

    func testTextComesFromDonkCrashFormatter() {
        let report = sampleCrash()
        XCTAssertEqual(LiveCrashProvider().text(for: report), DonkCrash.textReport(for: report))
    }
}
