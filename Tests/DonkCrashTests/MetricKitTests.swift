import XCTest
@testable import DonkCrash

final class MetricKitTests: XCTestCase {
    private let crashTree = """
    {
      "callStackPerThread": true,
      "callStacks": [
        {
          "threadAttributed": false,
          "callStackRootFrames": [
            { "binaryUUID": "aaaaaaaa-0000-0000-0000-000000000000", "offsetIntoBinaryTextSegment": 1, "binaryName": "libsystem_kernel.dylib", "address": 7000000001, "sampleCount": 1 }
          ]
        },
        {
          "threadAttributed": true,
          "callStackRootFrames": [
            {
              "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
              "offsetIntoBinaryTextSegment": 165304,
              "sampleCount": 1,
              "binaryName": "DonkDemo",
              "address": 4339007928,
              "subFrames": [
                {
                  "binaryUUID": "BBBBBBBB-0000-0000-0000-000000000000",
                  "offsetIntoBinaryTextSegment": 79028,
                  "sampleCount": 1,
                  "binaryName": "libswiftCore.dylib",
                  "address": 7399923188,
                  "subFrames": [
                    { "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment": 2000, "sampleCount": 1, "binaryName": "DonkDemo", "address": 4338844624 }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """

    private let hangTree = """
    {
      "callStackPerThread": false,
      "callStacks": [
        {
          "callStackRootFrames": [
            { "binaryName": "A", "binaryUUID": "11111111-0000-0000-0000-000000000000", "offsetIntoBinaryTextSegment": 16, "address": 4096016, "sampleCount": 3 },
            {
              "binaryName": "B", "binaryUUID": "22222222-0000-0000-0000-000000000000", "offsetIntoBinaryTextSegment": 32, "address": 8192032, "sampleCount": 9,
              "subFrames": [
                { "binaryName": "C", "offsetIntoBinaryTextSegment": 1, "address": 100, "sampleCount": 2 },
                { "binaryName": "D", "offsetIntoBinaryTextSegment": 2, "address": 200, "sampleCount": 7 }
              ]
            }
          ]
        }
      ]
    }
    """

    func testAttributedThreadIsFlattenedInnermostFirst() {
        let frames = MetricKitCallStack.attributedFrames(from: Data(crashTree.utf8))
        XCTAssertEqual(frames.map(\.binaryName), ["DonkDemo", "libswiftCore.dylib", "DonkDemo"])
        XCTAssertEqual(frames.map(\.address), [4_339_007_928, 7_399_923_188, 4_338_844_624])
        XCTAssertEqual(frames[0].offset, 165_304)
        XCTAssertEqual(frames[0].binaryUUID, "70B89F27-1634-3580-A695-57CDB41D7743")
        XCTAssertEqual(frames[1].binaryUUID, "BBBBBBBB-0000-0000-0000-000000000000")
    }

    func testSampleTreeFollowsHeaviestPath() {
        let frames = MetricKitCallStack.attributedFrames(from: Data(hangTree.utf8))
        XCTAssertEqual(frames.map(\.binaryName), ["B", "D"])
    }

    func testMalformedJSONYieldsNoFrames() {
        XCTAssertTrue(MetricKitCallStack.attributedFrames(from: Data("[]".utf8)).isEmpty)
        XCTAssertTrue(MetricKitCallStack.attributedFrames(from: Data("{\"callStacks\":[]}".utf8)).isEmpty)
    }

    func testDiagnosticBecomesReport() {
        let diagnostic = MetricKitDiagnostic(
            category: .crash,
            title: "EXC_BAD_ACCESS / SIGSEGV",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            version: "2.0",
            build: "200",
            osVersion: "iPhone OS 17.0 (21A329)",
            deviceType: "iPhone15,2",
            architecture: "arm64e",
            processID: 321,
            details: [CrashDetail("Termination reason", "Namespace SIGNAL, Code 11")],
            callStackJSON: Data(crashTree.utf8),
            signature: "x"
        )
        let symbolicator = Symbolicator(loaded: [], currentBundlePath: "/z/DonkDemo.app") { _ in nil }
        let report = MetricKitConverter.report(from: diagnostic, symbolicator: symbolicator, current: testLaunchInfo())
        XCTAssertEqual(report.kind, .metricKit)
        XCTAssertEqual(report.title, "EXC_BAD_ACCESS / SIGSEGV")
        XCTAssertEqual(report.appVersion, "2.0")
        XCTAssertEqual(report.appBuild, "200")
        XCTAssertEqual(report.osVersion, "iPhone OS 17.0 (21A329)")
        XCTAssertEqual(report.frames.count, 3)
        XCTAssertEqual(report.frames[0].imageLoadAddress, 4_339_007_928 - 165_304)
        XCTAssertEqual(report.frames[0].imageOffset, 165_304)
        XCTAssertTrue(report.frames[0].isAppFrame)
        XCTAssertFalse(report.frames[1].isAppFrame)
        XCTAssertEqual(report.binaryImages.count, 2)
        XCTAssertEqual(report.binaryImages.first { $0.isMainExecutable }?.name, "DonkDemo")
        XCTAssertEqual(report.subtitle, "Namespace SIGNAL, Code 11")
        XCTAssertEqual(MetricKitConverter.machExceptionName(1), "EXC_BAD_ACCESS")
        XCTAssertEqual(MetricKitConverter.machExceptionName(99), "EXC_99")
    }

    func testSignatureIsStable() {
        let data = Data("payload".utf8)
        let date = Date(timeIntervalSince1970: 1234)
        XCTAssertEqual(MetricKitConverter.signature(category: .crash, date: date, payload: data), MetricKitConverter.signature(category: .crash, date: date, payload: data))
        XCTAssertNotEqual(MetricKitConverter.signature(category: .crash, date: date, payload: data), MetricKitConverter.signature(category: .hang, date: date, payload: data))
        XCTAssertEqual(MetricKitConverter.signature(category: .crash, date: date, payload: Data()), "crash-1234-cbf29ce484222325")
    }
}
