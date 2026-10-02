import Foundation
import XCTest
@testable import DonkPush

enum PushTestSupport {
    static func temporaryDirectory(_ name: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DonkPushTests", isDirectory: true)
            .appendingPathComponent("\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func payload(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> PushPayload {
        switch PushPayload.parse(text) {
        case let .success(payload):
            return payload
        case let .failure(error):
            XCTFail("Payload failed to parse: \(error)", file: file, line: line)
            return try! PushPayload.parse("{}").get()
        }
    }

    static func dictionary(_ text: String) -> [String: Any] {
        payload(text).dictionary
    }
}
