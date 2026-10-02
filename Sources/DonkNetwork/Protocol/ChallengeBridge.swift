import DonkCore
import Foundation

package final class ChallengeBridge: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    package typealias Completion = (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    private let lock = DonkLock()
    private var completion: Completion?

    package init(completion: @escaping Completion) {
        self.completion = completion
    }

    package var isPending: Bool {
        lock.withLock { completion != nil }
    }

    package func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        complete(.useCredential, credential)
    }

    package func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        complete(.useCredential, nil)
    }

    package func cancel(_ challenge: URLAuthenticationChallenge) {
        complete(.cancelAuthenticationChallenge, nil)
    }

    package func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        complete(.performDefaultHandling, nil)
    }

    package func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        complete(.rejectProtectionSpace, nil)
    }

    package func cancelIfPending() {
        complete(.cancelAuthenticationChallenge, nil)
    }

    private func complete(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        let handler: Completion? = lock.withLock {
            defer { completion = nil }
            return completion
        }
        handler?(disposition, credential)
    }
}
