import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

private struct FakeTransaction: TransactionMetricsSource {
    var fetchStartDate: Date? = Date(timeIntervalSince1970: 100)
    var domainLookupStartDate: Date? = Date(timeIntervalSince1970: 101)
    var domainLookupEndDate: Date? = Date(timeIntervalSince1970: 102)
    var connectStartDate: Date? = Date(timeIntervalSince1970: 103)
    var connectEndDate: Date? = Date(timeIntervalSince1970: 106)
    var secureConnectionStartDate: Date? = Date(timeIntervalSince1970: 104)
    var secureConnectionEndDate: Date? = Date(timeIntervalSince1970: 105)
    var requestStartDate: Date? = Date(timeIntervalSince1970: 107)
    var requestEndDate: Date? = Date(timeIntervalSince1970: 108)
    var responseStartDate: Date? = Date(timeIntervalSince1970: 109)
    var responseEndDate: Date? = Date(timeIntervalSince1970: 110)
    var networkProtocolName: String? = "h2"
    var isProxyConnection = true
    var isReusedConnection = true
    var remoteAddressValue: String? = "93.184.216.34"
    var remotePortValue: Int? = 443
    var tlsProtocolVersionValue: UInt16? = 0x0304
    var tlsCipherSuiteValue: UInt16? = 0x1301
    var requestHeaderBytes: Int64 = 120
    var requestBodyBytes: Int64 = 42
    var responseHeaderBytes: Int64 = 300
    var responseBodyBytes: Int64 = 4096
}

final class MetricsMapperTests: XCTestCase {
    func testMapsAllFields() {
        let metrics = MetricsMapper.map(FakeTransaction())
        XCTAssertEqual(metrics.fetchStart, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(metrics.domainLookupStart, Date(timeIntervalSince1970: 101))
        XCTAssertEqual(metrics.domainLookupEnd, Date(timeIntervalSince1970: 102))
        XCTAssertEqual(metrics.connectStart, Date(timeIntervalSince1970: 103))
        XCTAssertEqual(metrics.secureConnectionStart, Date(timeIntervalSince1970: 104))
        XCTAssertEqual(metrics.secureConnectionEnd, Date(timeIntervalSince1970: 105))
        XCTAssertEqual(metrics.connectEnd, Date(timeIntervalSince1970: 106))
        XCTAssertEqual(metrics.requestStart, Date(timeIntervalSince1970: 107))
        XCTAssertEqual(metrics.requestEnd, Date(timeIntervalSince1970: 108))
        XCTAssertEqual(metrics.responseStart, Date(timeIntervalSince1970: 109))
        XCTAssertEqual(metrics.responseEnd, Date(timeIntervalSince1970: 110))
        XCTAssertEqual(metrics.networkProtocol, "HTTP/2")
        XCTAssertEqual(metrics.remoteAddress, "93.184.216.34:443")
        XCTAssertEqual(metrics.tlsProtocol, "TLS 1.3")
        XCTAssertEqual(metrics.tlsCipherSuite, "TLS_AES_128_GCM_SHA256")
        XCTAssertTrue(metrics.isProxyConnection)
        XCTAssertTrue(metrics.isReusedConnection)
        XCTAssertEqual(metrics.requestHeaderBytes, 120)
        XCTAssertEqual(metrics.requestBodyBytes, 42)
        XCTAssertEqual(metrics.responseHeaderBytes, 300)
        XCTAssertEqual(metrics.responseBodyBytes, 4096)
    }

    func testHumanReadableNames() {
        XCTAssertEqual(MetricsMapper.protocolName("http/1.1"), "HTTP/1.1")
        XCTAssertEqual(MetricsMapper.protocolName("h3"), "HTTP/3")
        XCTAssertEqual(MetricsMapper.protocolName("h3-29"), "HTTP/3")
        XCTAssertNil(MetricsMapper.protocolName(""))
        XCTAssertEqual(MetricsMapper.address("2606:4700::6810:84e5", port: 443), "[2606:4700::6810:84e5]:443")
        XCTAssertEqual(MetricsMapper.address("10.0.0.1", port: nil), "10.0.0.1")
        XCTAssertNil(MetricsMapper.address(nil, port: 80))
        XCTAssertEqual(MetricsMapper.tlsVersionName(0x0303), "TLS 1.2")
        XCTAssertNil(MetricsMapper.tlsVersionName(0))
        XCTAssertEqual(MetricsMapper.cipherSuiteName(0xC02F), "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256")
        XCTAssertEqual(MetricsMapper.cipherSuiteName(0xABCD), "0xABCD")
    }

    func testMissingValuesStayNil() {
        var fake = FakeTransaction()
        fake.networkProtocolName = nil
        fake.remoteAddressValue = nil
        fake.tlsProtocolVersionValue = nil
        fake.tlsCipherSuiteValue = nil
        fake.requestBodyBytes = -1
        let metrics = MetricsMapper.map(fake)
        XCTAssertNil(metrics.networkProtocol)
        XCTAssertNil(metrics.remoteAddress)
        XCTAssertNil(metrics.tlsProtocol)
        XCTAssertNil(metrics.tlsCipherSuite)
        XCTAssertEqual(metrics.requestBodyBytes, 0)
    }
}

final class HTTPMessageTests: XCTestCase {
    func testInferredContentTypes() {
        XCTAssertEqual(HTTPMessage.inferredContentType(for: Data(#"{"a":1}"#.utf8)), "application/json; charset=utf-8")
        XCTAssertEqual(HTTPMessage.inferredContentType(for: Data("hello".utf8)), "text/plain; charset=utf-8")
        XCTAssertEqual(HTTPMessage.inferredContentType(for: Data("<!DOCTYPE html><html></html>".utf8)), "text/html; charset=utf-8")
        XCTAssertEqual(HTTPMessage.inferredContentType(for: Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])), "image/jpeg")
        XCTAssertEqual(HTTPMessage.inferredContentType(for: Data([0x00, 0xFE, 0xFF, 0x80])), "application/octet-stream")
    }

    func testJoinedHeadersMergeDuplicates() {
        let joined = HTTPMessage.joined([
            HTTPHeader(name: "Accept", value: "a"),
            HTTPHeader(name: "accept", value: "b"),
            HTTPHeader(name: " ", value: "ignored"),
            HTTPHeader(name: "X-One", value: "1"),
        ])
        XCTAssertEqual(joined, ["Accept": "a, b", "X-One": "1"])
    }

    func testMockResponseSynthesis() {
        let parts = HTTPMessage.responseParts(MockResponse(statusCode: 0, body: "[1,2]"), url: URL(string: "https://x.test")!)
        XCTAssertEqual(parts.statusCode, 200)
        XCTAssertEqual(parts.headers.value(for: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(parts.headers.value(for: "Content-Length"), "5")
        let response = HTTPMessage.makeResponse(parts)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "content-type"), "application/json; charset=utf-8")
        let empty = HTTPMessage.responseParts(MockResponse(statusCode: 204), url: URL(string: "https://x.test")!)
        XCTAssertNil(empty.headers.value(for: "Content-Type"))
        XCTAssertEqual(empty.headers.value(for: "Content-Length"), "0")
    }

    func testResponseRewriteFixesContentLength() {
        var parts = ResponseParts(url: URL(string: "https://x.test")!, statusCode: 200, headers: [HTTPHeader(name: "Content-Length", value: "3")], body: Data("abc".utf8))
        HTTPMessage.apply(ResponseRewrite(body: .replace("abcdef")), to: &parts)
        XCTAssertEqual(parts.headers.value(for: "Content-Length"), "6")
        XCTAssertEqual(parts.body, Data("abcdef".utf8))
    }

    func testEditableRequestRoundTrip() {
        var request = URLRequest(url: URL(string: "https://x.test/a")!)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "X-A")
        var parts = RequestParts(request: request, body: .data(Data("body".utf8)))
        let original = HTTPMessage.editable(parts)
        XCTAssertEqual(original.body, "body")
        XCTAssertFalse(original.bodyIsBinary)
        var edited = original
        edited.method = "patch"
        edited.url = "https://x.test/b"
        edited.headers = [HTTPHeader(name: "X-B", value: "2")]
        edited.body = "new"
        HTTPMessage.apply(edited, original: original, to: &parts)
        XCTAssertEqual(parts.method, "PATCH")
        XCTAssertEqual(parts.urlString, "https://x.test/b")
        XCTAssertEqual(parts.request.allHTTPHeaderFields, ["X-B": "2"])
        XCTAssertEqual(parts.body, .data(Data("new".utf8)))
    }

    func testBinaryBodiesBecomeBase64Editable() {
        let parts = RequestParts(request: URLRequest(url: URL(string: "https://x.test")!), body: .data(Data([0xFF, 0x00, 0xFE])))
        let editable = HTTPMessage.editable(parts)
        XCTAssertTrue(editable.bodyIsBinary)
        XCTAssertEqual(editable.bodyData, Data([0xFF, 0x00, 0xFE]))
    }

    func testPreparedInnerRequestIsMarkedAndBodyAligned() {
        var request = URLRequest(url: URL(string: "https://x.test")!)
        request.httpMethod = "POST"
        request.setValue("99", forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = InputStream(data: Data("ignored".utf8))
        let prepared = HTTPMessage.preparedInnerRequest(RequestParts(request: request, body: .data(Data("four".utf8))))
        XCTAssertEqual(prepared.httpBody, Data("four".utf8))
        XCTAssertNil(prepared.httpBodyStream)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Content-Length"), "4")
        XCTAssertEqual(URLProtocol.property(forKey: DonkURLProtocol.handledKey, in: prepared) as? Bool, true)
    }

    func testMergedHeadersOnlyAddMissingNames() {
        let merged = HTTPMessage.mergedHeaders(
            [HTTPHeader(name: "Accept", value: "application/json"), HTTPHeader(name: "X-App", value: "1")],
            extra: [HTTPHeader(name: "accept", value: "*/*"), HTTPHeader(name: "User-Agent", value: "UA"), HTTPHeader(name: "Cookie", value: "a=b")]
        )
        XCTAssertEqual(merged.value(for: "Accept"), "application/json")
        XCTAssertEqual(merged.value(for: "User-Agent"), "UA")
        XCTAssertEqual(merged.value(for: "Cookie"), "a=b")
        XCTAssertEqual(merged.count, 4)
    }

    func testStreamingContentTypes() {
        XCTAssertTrue(HTTPMessage.isStreamingContentType("text/event-stream; charset=utf-8"))
        XCTAssertTrue(HTTPMessage.isStreamingContentType("application/x-ndjson"))
        XCTAssertFalse(HTTPMessage.isStreamingContentType("application/json"))
        XCTAssertFalse(HTTPMessage.isStreamingContentType(nil))
    }

    func testOriginRanking() {
        XCTAssertLessThan(HTTPExchange.rank(.network), HTTPExchange.rank(.breakpoint(edited: false)))
        XCTAssertLessThan(HTTPExchange.rank(.breakpoint(edited: false)), HTTPExchange.rank(.breakpoint(edited: true)))
        XCTAssertLessThan(HTTPExchange.rank(.breakpoint(edited: true)), HTTPExchange.rank(.rewritten(rule: "r")))
        XCTAssertLessThan(HTTPExchange.rank(.rewritten(rule: "r")), HTTPExchange.rank(.mocked(rule: "m")))
    }
}

final class BodyStreamReaderTests: XCTestCase {
    func testReadsSmallStreamIntoMemory() throws {
        let result = BodyStreamReader.readSynchronously(InputStream(data: Data("abc".utf8)), captureLimit: 2)
        XCTAssertEqual(try result.get(), .data(Data("abc".utf8)))
    }

    func testEmptyStreamIsNone() throws {
        XCTAssertEqual(try BodyStreamReader.readSynchronously(InputStream(data: Data()), captureLimit: 10).get(), RequestBody.none)
    }

    func testLargeStreamSpillsToFile() throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 256) })
        let body = try BodyStreamReader.readSynchronously(InputStream(data: payload), captureLimit: 1000, spillThreshold: 100_000).get()
        guard case let .file(url, size, prefix) = body else { return XCTFail("expected file body") }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(size, payload.count)
        XCTAssertEqual(prefix, payload.prefix(1000))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(body.loadData(), payload)
        XCTAssertEqual(HTTPMessage.bodyData(body, contentType: nil, limit: 1000)?.originalSize, payload.count)
        XCTAssertEqual(HTTPMessage.bodyData(body, contentType: nil, limit: 1000)?.isTruncated, true)
    }

    func testLargeFileUploadIsCapturedEndToEnd() {
        let reading = expectation(description: "read")
        let pair = Self.boundStream(payload: Data(repeating: 1, count: 50_000))
        BodyStreamReader.read(pair, captureLimit: 100) { result in
            XCTAssertEqual((try? result.get())?.size, 50_000)
            reading.fulfill()
        }
        wait(for: [reading], timeout: 5)
    }

    func testReaderStopsBetweenReadsWhenCancelled() throws {
        let flag = CancelFlag()
        let before = Self.spillFiles()
        let reading = expectation(description: "read")
        let started = Date()
        var outcome: Result<RequestBody, Error>?
        BodyStreamReader.read(Self.slowStream(chunks: 400, interval: 0.01), captureLimit: 64, spillThreshold: 1024, isCancelled: { flag.isSet }) { result in
            outcome = result
            reading.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { flag.set() }
        wait(for: [reading], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case let .failure(error)? = outcome else { return XCTFail("expected cancellation") }
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
        XCTAssertEqual(Self.spillFiles(), before)
    }

    func testStaleSpillFilesAreRemovedBeforeLaterReads() throws {
        let directory = BodyStreamReader.spillDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("stale-\(UUID().uuidString)")
        try Data(repeating: 1, count: 16).write(to: stale)
        BodyStreamReader.removeSpillFiles()
        let reading = expectation(description: "read")
        var existedDuringRead = true
        BodyStreamReader.read(InputStream(data: Data("x".utf8)), captureLimit: 10) { _ in
            existedDuringRead = FileManager.default.fileExists(atPath: stale.path)
            reading.fulfill()
        }
        wait(for: [reading], timeout: 5)
        XCTAssertFalse(existedDuringRead)
    }

    private static func spillFiles() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: BodyStreamReader.spillDirectory.path)) ?? [])
    }

    private static func slowStream(chunks: Int, interval: TimeInterval) -> InputStream {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &input, outputStream: &output)
        let writer = output!
        DispatchQueue.global().async {
            writer.open()
            let chunk = [UInt8](repeating: 7, count: 1024)
            for _ in 0..<chunks {
                let written = chunk.withUnsafeBufferPointer { writer.write($0.baseAddress!, maxLength: $0.count) }
                if written <= 0 { break }
                Thread.sleep(forTimeInterval: interval)
            }
            writer.close()
        }
        return input!
    }

    private static func boundStream(payload: Data) -> InputStream {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &input, outputStream: &output)
        let writer = output!
        DispatchQueue.global().async {
            writer.open()
            var offset = 0
            let bytes = [UInt8](payload)
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBufferPointer { writer.write($0.baseAddress!, maxLength: min(1024, $0.count)) }
                if written <= 0 { break }
                offset += written
            }
            writer.close()
        }
        return input!
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withValue { value } }

    func set() {
        lock.withValue { value = true }
    }
}

final class ClientChannelTests: XCTestCase {
    func testBlocksRunOnCapturedThreadInOrderAndModes() {
        let ready = expectation(description: "thread ready")
        let finished = expectation(description: "blocks ran")
        var channel: ClientChannel?
        let customMode = RunLoop.Mode("dev.donk.tests.mode")
        let thread = Thread {
            channel = ClientChannel(thread: .current, currentMode: customMode)
            ready.fulfill()
            let runLoop = RunLoop.current
            runLoop.add(Port(), forMode: .default)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                runLoop.run(mode: customMode, before: Date().addingTimeInterval(0.05))
            }
        }
        thread.start()
        wait(for: [ready], timeout: 2)
        let lock = NSLock()
        var order: [Int] = []
        var threads: [Thread] = []
        let target = try! XCTUnwrap(channel)
        XCTAssertEqual(target.modes, [RunLoop.Mode.default.rawValue, customMode.rawValue])
        for index in 0..<5 {
            target.perform {
                lock.withValue {
                    order.append(index)
                    threads.append(.current)
                    if order.count == 5 { finished.fulfill() }
                }
            }
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        XCTAssertTrue(threads.allSatisfy { $0 === thread })
        thread.cancel()
    }
}
