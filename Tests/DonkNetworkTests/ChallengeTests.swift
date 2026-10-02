import DonkCore
import Foundation
import XCTest
@testable import DonkNetwork

final class ChallengeTests: CaptureTestCase {
    override func setUp() {
        super.setUp()
        StubServer.shared.route("/secure", [.challenge(NSURLAuthenticationMethodHTTPBasic), .respond(200, ["Content-Type": "text/plain"]), .text("secret"), .finish])
        StubServer.shared.route("/trust", [.challenge(NSURLAuthenticationMethodServerTrust), .respond(200, [:]), .text("trusted"), .finish])
    }

    func testChallengeIsForwardedToOuterDelegateWithCredential() async throws {
        let delegate = RecordingDelegate()
        delegate.challengeDisposition = .useCredential
        delegate.challengeCredential = URLCredential(user: "ada", password: "lovelace", persistence: .none)
        makeSession(delegate: delegate).dataTask(with: url("/secure")).resume()
        await delegate.waitForCompletion()

        XCTAssertNil(delegate.error)
        XCTAssertEqual(String(decoding: delegate.body, as: UTF8.self), "secret")
        XCTAssertEqual(delegate.challenges.count, 1)
        XCTAssertEqual(delegate.challenges.first?.protectionSpace.authenticationMethod, NSURLAuthenticationMethodHTTPBasic)
        XCTAssertEqual(delegate.challenges.first?.protectionSpace.realm, "stub")
        XCTAssertEqual(StubServer.shared.challengeOutcomes, ["use:ada"])
        let finished1 = await finishedEntry(path: "/secure")
        XCTAssertEqual(finished1?.state, .completed)
    }

    func testDefaultHandlingFromDelegate() async throws {
        let delegate = RecordingDelegate()
        delegate.challengeDisposition = .performDefaultHandling
        makeSession(delegate: delegate).dataTask(with: url("/trust")).resume()
        await delegate.waitForCompletion()
        XCTAssertNil(delegate.error)
        XCTAssertEqual(delegate.challenges.first?.protectionSpace.authenticationMethod, NSURLAuthenticationMethodServerTrust)
        XCTAssertEqual(StubServer.shared.challengeOutcomes, ["default"])
    }

    func testNilDelegateSessionFallsBackToDefaultHandling() async throws {
        let (data, _) = try await makeSession().data(from: url("/trust"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "trusted")
        XCTAssertEqual(StubServer.shared.challengeOutcomes, ["default"])
    }

    func testCancelledChallengeCancelsRequest() async throws {
        let delegate = RecordingDelegate()
        delegate.challengeDisposition = .cancelAuthenticationChallenge
        makeSession(delegate: delegate).dataTask(with: url("/secure")).resume()
        await delegate.waitForCompletion()
        XCTAssertEqual((delegate.error as? URLError)?.code, .cancelled)
        let finished2 = await finishedEntry(path: "/secure")
        XCTAssertEqual(finished2?.state, .cancelled)
        await waitUntil { StubServer.shared.stoppedPaths.contains("/secure") }
        XCTAssertTrue(StubServer.shared.stoppedPaths.contains("/secure"))
    }

    func testBridgeMapsEverySenderMessage() {
        let space = URLProtectionSpace(host: "h", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
        func challenge(_ sender: URLAuthenticationChallengeSender) -> URLAuthenticationChallenge {
            URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender)
        }
        func outcome(_ action: (ChallengeBridge, URLAuthenticationChallenge) -> Void) -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
            var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
            let bridge = ChallengeBridge { result = ($0, $1) }
            action(bridge, challenge(bridge))
            return result
        }
        let credential = URLCredential(user: "u", password: "p", persistence: .none)
        let used = outcome { $0.use(credential, for: $1) }
        XCTAssertEqual(used?.0, .useCredential)
        XCTAssertEqual(used?.1?.user, "u")
        let withoutCredential = outcome { $0.continueWithoutCredential(for: $1) }
        XCTAssertEqual(withoutCredential?.0, .useCredential)
        XCTAssertNil(withoutCredential?.1)
        XCTAssertEqual(outcome { $0.cancel($1) }?.0, .cancelAuthenticationChallenge)
        XCTAssertEqual(outcome { $0.performDefaultHandling(for: $1) }?.0, .performDefaultHandling)
        XCTAssertEqual(outcome { $0.rejectProtectionSpaceAndContinue(with: $1) }?.0, .rejectProtectionSpace)
        XCTAssertEqual(outcome { bridge, _ in bridge.cancelIfPending() }?.0, .cancelAuthenticationChallenge)
    }

    func testBridgeCompletesOnlyOnce() {
        var calls: [URLSession.AuthChallengeDisposition] = []
        let bridge = ChallengeBridge { disposition, _ in calls.append(disposition) }
        let space = URLProtectionSpace(host: "h", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodDefault)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: bridge)
        XCTAssertTrue(bridge.isPending)
        bridge.performDefaultHandling(for: challenge)
        bridge.cancel(challenge)
        bridge.cancelIfPending()
        XCTAssertFalse(bridge.isPending)
        XCTAssertEqual(calls, [.performDefaultHandling])
    }

    func testForwardedChallengeExposesBridgeAsSender() {
        let space = URLProtectionSpace(host: "h", port: 443, protocol: "https", realm: "r", authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        let original = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 2, failureResponse: nil, error: nil, sender: ChallengeBridge { _, _ in })
        let bridge = ChallengeBridge { _, _ in }
        let forwarded = URLAuthenticationChallenge(authenticationChallenge: original, sender: bridge)
        XCTAssertTrue(forwarded.sender === bridge)
        XCTAssertEqual(forwarded.previousFailureCount, 2)
        XCTAssertEqual(forwarded.protectionSpace, space)
    }
}
