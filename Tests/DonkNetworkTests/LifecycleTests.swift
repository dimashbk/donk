import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class LifecycleTests: CaptureTestCase {
    private func donkClasses(_ session: URLSession) -> [AnyClass] {
        (session.configuration.protocolClasses ?? []).filter { SessionInjector.isDonkClass($0) }
    }

    func testSwizzledFactoriesPrependProtocol() {
        let viaSwiftInit = URLSession(configuration: .default)
        let viaFullInit = URLSession(configuration: .ephemeral, delegate: RecordingDelegate(), delegateQueue: nil)
        defer {
            viaSwiftInit.invalidateAndCancel()
            viaFullInit.invalidateAndCancel()
        }
        for session in [viaSwiftInit, viaFullInit] {
            let classes = session.configuration.protocolClasses ?? []
            XCTAssertTrue(classes.first.map(SessionInjector.isDonkClass) ?? false)
            XCTAssertEqual(donkClasses(session).count, 1)
            XCTAssertNotNil(SessionInjector.context(of: session))
        }
        XCTAssertFalse(donkClasses(viaSwiftInit)[0] === donkClasses(viaFullInit)[0])
    }

    func testBackgroundAndInternalConfigurationsAreUntouched() {
        let background = URLSessionConfiguration.background(withIdentifier: "dev.donk.tests.\(UUID().uuidString)")
        let backgroundSession = URLSession(configuration: background)
        let internalConfiguration = URLSessionConfiguration.ephemeral
        DonkEnvironment.markInternal(internalConfiguration)
        let internalSession = URLSession(configuration: internalConfiguration)
        defer {
            backgroundSession.invalidateAndCancel()
            internalSession.invalidateAndCancel()
        }
        XCTAssertTrue(donkClasses(backgroundSession).isEmpty)
        XCTAssertTrue(donkClasses(internalSession).isEmpty)
        XCTAssertTrue(donkClasses(DonkEnvironment.internalSession).isEmpty)
    }

    func testInjectPrependsOnceAndSwizzleDedupes() throws {
        let configuration = URLSessionConfiguration.ephemeral
        DonkNetworkCapture.inject(into: configuration)
        DonkNetworkCapture.inject(into: configuration)
        let injected = (configuration.protocolClasses ?? []).filter { SessionInjector.isDonkClass($0) }
        XCTAssertEqual(injected.count, 1)
        let injectedClass: AnyClass = try XCTUnwrap(configuration.protocolClasses?.first)
        XCTAssertTrue(SessionInjector.isDonkClass(injectedClass))
        XCTAssertFalse(injectedClass === DonkURLProtocol.self)
        XCTAssertTrue(SessionContextRegistry.shared.isInjected(injectedClass))
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(donkClasses(session).count, 1)
        XCTAssertTrue(SessionInjector.context(of: session)?.outerSession === session)
    }

    func testInjectUsesPerConfigurationContext() throws {
        let cookies = HTTPCookieStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["X-Injected": "yes"]
        configuration.timeoutIntervalForRequest = 7
        configuration.httpCookieStorage = cookies
        configuration.urlCache = nil
        DonkNetworkCapture.inject(into: configuration)

        let injectedClass: AnyClass = try XCTUnwrap(configuration.protocolClasses?.first)
        let registry = SessionContextRegistry.shared
        let context = registry.context(for: injectedClass)
        XCTAssertFalse(context === registry.defaultContext)
        XCTAssertFalse(context.innerSession === registry.defaultContext.innerSession)
        let inner = context.innerConfiguration
        XCTAssertEqual(inner.timeoutIntervalForRequest, 7)
        XCTAssertTrue(inner.httpCookieStorage === cookies)
        XCTAssertNil(inner.urlCache)
        XCTAssertEqual(inner.httpAdditionalHeaders?["X-Injected"] as? String, "yes")
        XCTAssertEqual(context.additionalHeaders, [HTTPHeader(name: "X-Injected", value: "yes")])

        let other = URLSessionConfiguration.ephemeral
        DonkNetworkCapture.inject(into: other)
        XCTAssertFalse(other.protocolClasses?.first === injectedClass)
    }

    func testInjectedSessionCreatedBeforeStartCapturesWithItsConfiguration() async throws {
        DonkNetworkCapture.stop()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["X-Injected": "yes"]
        configuration.timeoutIntervalForRequest = 9
        DonkNetworkCapture.inject(into: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let context = try XCTUnwrap(SessionInjector.context(of: session))
        XCTAssertTrue(context.outerSession === session)
        XCTAssertFalse(context === SessionContextRegistry.shared.defaultContext)
        XCTAssertEqual(donkClasses(session).count, 1)

        DonkNetworkCapture.start(NetworkCaptureConfiguration())
        _ = try await session.data(from: url("/injected"))
        let entry = try await requireEntry(path: "/injected")
        XCTAssertEqual(entry.state, .completed)
        XCTAssertEqual(entry.request.header("X-Injected"), "yes")
        let record = try XCTUnwrap(StubServer.shared.records(path: "/injected").first)
        XCTAssertTrue(record.isHandled)
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-Injected"), "yes")
        XCTAssertEqual(context.innerConfiguration.timeoutIntervalForRequest, 9)
    }

    func testStartIsIdempotentAndStopDisablesCapture() async throws {
        DonkNetworkCapture.start(NetworkCaptureConfiguration())
        DonkNetworkCapture.start(NetworkCaptureConfiguration())
        XCTAssertTrue(DonkNetworkCapture.isRunning)
        let session = makeSession(stubFallback: true)
        XCTAssertEqual(donkClasses(session).count, 1)
        _ = try await session.data(from: url("/before-stop"))
        let finished1 = await finishedEntry(path: "/before-stop")
        XCTAssertEqual(finished1?.state, .completed)

        DonkNetworkCapture.stop()
        DonkNetworkCapture.stop()
        XCTAssertFalse(DonkNetworkCapture.isRunning)
        let (data, _) = try await session.data(from: url("/after-stop"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/after-stop"))
        XCTAssertNil(entry(path: "/after-stop"))
        let createdWhileStopped = makeSession()
        XCTAssertTrue(donkClasses(createdWhileStopped).isEmpty)

        DonkNetworkCapture.start(NetworkCaptureConfiguration())
        _ = try await session.data(from: url("/restarted"))
        let finished2 = await finishedEntry(path: "/restarted")
        XCTAssertEqual(finished2?.state, .completed)
    }

    func testStartWithDisabledConfigurationDoesNotCapture() async throws {
        var configuration = NetworkCaptureConfiguration()
        configuration.isEnabled = false
        DonkNetworkCapture.start(configuration)
        XCTAssertFalse(DonkNetworkCapture.isRunning)
        let session = makeSession(stubFallback: true)
        _ = try await session.data(from: url("/disabled-config"))
        XCTAssertNil(entry(path: "/disabled-config"))
    }

    func testCaptureSwitchOnStore() async throws {
        store.isCaptureEnabled = false
        let session = makeSession(stubFallback: true)
        let (data, _) = try await session.data(from: url("/switched-off"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/switched-off"))
        XCTAssertNil(entry(path: "/switched-off"))
        XCTAssertEqual(StubServer.shared.records(path: "/switched-off").first?.isHandled, false)
        store.isCaptureEnabled = true
        _ = try await session.data(from: url("/switched-on"))
        let finished3 = await finishedEntry(path: "/switched-on")
        XCTAssertNotNil(finished3)
    }

    func testBypassHostsFromConfigurationAndSettings() async throws {
        var configuration = NetworkCaptureConfiguration()
        configuration.bypassHosts = ["skip.donk.test"]
        DonkNetworkCapture.start(configuration)
        settings.settings = NetworkSettings(bypassHosts: ["*.private.donk.test"])
        let session = makeSession(stubFallback: true)
        _ = try await session.data(from: url("/a", host: "skip.donk.test"))
        _ = try await session.data(from: url("/b", host: "deep.private.donk.test"))
        _ = try await session.data(from: url("/c", host: "api.donk.test"))
        XCTAssertNil(entry(path: "/a"))
        XCTAssertNil(entry(path: "/b"))
        let finished4 = await finishedEntry(path: "/c")
        XCTAssertNotNil(finished4)
        XCTAssertEqual(StubServer.shared.allRecords.count, 3)
    }

    func testInternalMarkerSkipsCapture() async throws {
        let session = makeSession(stubFallback: true)
        let marked = HTTPMessage.marked(URLRequest(url: url("/internal")), key: DonkEnvironment.internalRequestKey, value: true)
        _ = try await session.data(for: marked)
        XCTAssertNil(entry(path: "/internal"))
        XCTAssertEqual(StubServer.shared.records(path: "/internal").count, 1)
    }

    func testWebSocketUpgradeAndNonHTTPSchemesAreSkipped() {
        var upgrade = URLRequest(url: url("/socket"))
        upgrade.setValue("websocket", forHTTPHeaderField: "Upgrade")
        XCTAssertFalse(DonkURLProtocol.canInit(with: upgrade))
        XCTAssertFalse(DonkURLProtocol.canInit(with: URLRequest(url: URL(string: "ftp://donk.test/file")!)))
        XCTAssertFalse(DonkURLProtocol.canInit(with: URLRequest(url: URL(string: "wss://donk.test/socket")!)))
        XCTAssertTrue(DonkURLProtocol.canInit(with: URLRequest(url: url("/ok"))))
        let socketTask = URLSession.shared.webSocketTask(with: URL(string: "wss://api.donk.test/socket")!)
        XCTAssertFalse(DonkURLProtocol.canInit(with: socketTask))
        let handled = HTTPMessage.marked(URLRequest(url: url("/handled")), key: DonkURLProtocol.handledKey, value: true)
        XCTAssertFalse(DonkURLProtocol.canInit(with: handled))
    }

    func testContextsAreRecycledWhenSessionsGoAway() async throws {
        let registry = SessionContextRegistry.shared
        weak var weakContext: SessionContext?
        var protocolClass: AnyClass?
        autoreleasepool {
            let session = URLSession(configuration: .ephemeral)
            weakContext = SessionInjector.context(of: session)
            protocolClass = donkClasses(session).first
            session.invalidateAndCancel()
        }
        await waitUntil(timeout: 5) { weakContext == nil }
        XCTAssertNil(weakContext)
        let recycledClass: AnyClass = try XCTUnwrap(protocolClass)
        XCTAssertTrue(registry.isRecycled(recycledClass))
        let allocated = registry.allocatedClassCount
        let recycled = URLSession(configuration: .ephemeral)
        defer { recycled.invalidateAndCancel() }
        XCTAssertEqual(registry.allocatedClassCount, allocated)
        XCTAssertEqual(donkClasses(recycled).count, 1)
    }

    func testRegisteredClassUsesDefaultContext() {
        XCTAssertTrue(SessionContextRegistry.shared.context(for: DonkURLProtocol.self) === SessionContextRegistry.shared.defaultContext)
    }
}
