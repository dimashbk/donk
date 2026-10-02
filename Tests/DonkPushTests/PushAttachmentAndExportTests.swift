import DonkCore
import UIKit
import UserNotifications
import XCTest
@testable import DonkPush

final class PushAttachmentURLTests: XCTestCase {
    private let defaultKeyPaths = PushConfiguration().attachmentURLKeyPaths

    func testNestedFCMImage() {
        let payload = PushTestSupport.dictionary(#"{"aps":{},"fcm_options":{"image":"https://cdn.example.com/a.png"}}"#)
        XCTAssertEqual(PushJSON.attachmentURL(in: payload, keyPaths: defaultKeyPaths)?.absoluteString, "https://cdn.example.com/a.png")
    }

    func testTopLevelKeysAndPriority() {
        let payload = PushTestSupport.dictionary(#"{"image":"https://x.test/second.jpg","imageUrl":"https://x.test/first.jpg"}"#)
        XCTAssertEqual(PushJSON.attachmentURL(in: payload, keyPaths: defaultKeyPaths)?.lastPathComponent, "first.jpg")
        XCTAssertEqual(PushJSON.attachmentURL(in: payload, keyPaths: ["image", "imageUrl"])?.lastPathComponent, "second.jpg")
    }

    func testSkipsInvalidValues() {
        let payload = PushTestSupport.dictionary(#"{"imageUrl":"not a url","image":"ftp://x.test/a.png","attachment-url":42,"media-url":" https://x.test/ok.gif "}"#)
        XCTAssertEqual(PushJSON.attachmentURL(in: payload, keyPaths: defaultKeyPaths)?.absoluteString, "https://x.test/ok.gif")
    }

    func testLiteralDottedKeyAndArrayIndex() {
        let payload = PushTestSupport.dictionary(#"{"media.url":"https://x.test/literal.png","data":{"attachments":[{"url":"https://x.test/indexed.png"}]}}"#)
        XCTAssertEqual(PushJSON.attachmentURL(in: payload, keyPaths: ["media.url"])?.lastPathComponent, "literal.png")
        XCTAssertEqual(PushJSON.attachmentURL(in: payload, keyPaths: ["data.attachments.0.url"])?.lastPathComponent, "indexed.png")
        XCTAssertNil(PushJSON.attachmentURL(in: payload, keyPaths: ["data.attachments.3.url", "missing.path"]))
    }

    func testPayloadConvenience() {
        let payload = PushTestSupport.payload(#"{"aps":{"mutable-content":1},"fcm_options":{"image":"https://x.test/p.webp"}}"#)
        XCTAssertEqual(payload.attachmentURL(keyPaths: defaultKeyPaths)?.pathExtension, "webp")
        XCTAssertNil(payload.attachmentURL(keyPaths: []))
    }

    func testFileExtensionFromMIMEType() {
        let url = URL(string: "https://x.test/download")!
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: "image/png", url: url), "png")
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: "image/jpeg; charset=binary", url: url), "jpg")
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: "video/mp4", url: url), "mp4")
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: "audio/mpeg", url: url), "mp3")
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: nil, url: URL(string: "https://x.test/a.GIF")!), "gif")
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: nil, url: URL(string: "https://x.test/a.jpeg")!), "jpg")
        XCTAssertEqual(PushAttachmentLoader.fileExtension(mimeType: "application/x-unknown-thing", url: url), "jpg")
    }
}

final class PushAttachMediaTests: XCTestCase {
    private func imageURL() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let url = PushTestSupport.temporaryDirectory().appendingPathComponent("pixel.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }

    private func content(_ userInfo: [AnyHashable: Any]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Host title"
        content.userInfo = userInfo
        return content
    }

    func testAttachesFirstMatchingURL() async throws {
        let url = try imageURL()
        let original = content(["aps": ["mutable-content": 1], "imageUrl": url.absoluteString])
        let result = await DonkPush.attachMedia(to: original)
        XCTAssertTrue(result === original)
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.title, "Host title")
    }

    func testCustomKeyPaths() async throws {
        let url = try imageURL()
        let missed = await DonkPush.attachMedia(to: content(["data": ["picture": url.absoluteString]]))
        XCTAssertTrue(missed.attachments.isEmpty)
        let found = await DonkPush.attachMedia(to: content(["data": ["picture": url.absoluteString]]), keyPaths: ["data.picture"])
        XCTAssertEqual(found.attachments.count, 1)
    }

    func testLeavesContentUntouchedWithoutURLOrOnFailure() async {
        let empty = await DonkPush.attachMedia(to: content(["aps": ["mutable-content": 1]]))
        XCTAssertTrue(empty.attachments.isEmpty)
        let missingFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let failed = await DonkPush.attachMedia(to: content(["image": missingFile.absoluteString]))
        XCTAssertTrue(failed.attachments.isEmpty)
        XCTAssertEqual(failed.title, "Host title")
    }
}

final class PushExportTests: XCTestCase {
    func testAPNsFileAppendsTargetBundleAndKeepsOrder() throws {
        let payload = PushTestSupport.payload(#"{"aps":{"alert":"Hi"},"zeta":1,"alpha":{"b":true}}"#)
        let contents = PushAPNsExport.fileContents(payload: payload.value, bundleID: "io.example.app")
        let value = try JSONValue.parse(contents)
        guard case let .object(members) = value else { return XCTFail("Not an object") }
        XCTAssertEqual(members.map(\.key), ["aps", "zeta", "alpha", "Simulator Target Bundle"])
        XCTAssertEqual(value["Simulator Target Bundle"], .string("io.example.app"))
        XCTAssertEqual(value["aps"], payload.value["aps"])
        XCTAssertEqual(value["alpha"], payload.value["alpha"])
    }

    func testAPNsFileReplacesExistingTargetBundle() throws {
        let payload = PushTestSupport.payload(#"{"Simulator Target Bundle":"old","aps":{"badge":1}}"#)
        let value = try JSONValue.parse(PushAPNsExport.fileContents(payload: payload.value, bundleID: "new.bundle"))
        guard case let .object(members) = value else { return XCTFail("Not an object") }
        XCTAssertEqual(members.filter { $0.key == "Simulator Target Bundle" }.count, 1)
        XCTAssertEqual(value["Simulator Target Bundle"], .string("new.bundle"))
    }

    func testAPNsFileWithoutTargetBundleIsExactlyThePayload() throws {
        let payload = PushTestSupport.payload(#"{"aps":{"alert":"Hi"},"Simulator Target Bundle":"stale","k":[1,2]}"#)
        let value = try JSONValue.parse(PushAPNsExport.fileContents(payload: payload.value, bundleID: nil))
        XCTAssertNil(value["Simulator Target Bundle"])
        XCTAssertEqual(value["aps"], payload.value["aps"])
        XCTAssertEqual(value["k"], payload.value["k"])
    }

    func testCommand() {
        XCTAssertEqual(PushAPNsExport.command(bundleID: "io.example.app"), "xcrun simctl push booted io.example.app payload.apns")
    }

    func testBuiltInTemplatesAreValidPayloads() {
        XCTAssertEqual(PushBuiltInTemplates.all.count, 6)
        for template in PushBuiltInTemplates.all {
            guard case let .success(payload) = PushPayload.parse(template.payload) else {
                return XCTFail("\(template.name) is not valid")
            }
            XCTAssertTrue(payload.hasAPS, template.name)
        }
        XCTAssertEqual(Set(PushBuiltInTemplates.all.map(\.id)).count, 6)
    }
}
