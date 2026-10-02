import DonkCore
import Foundation

package final class InnerSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    package static let shared = InnerSessionDelegate()

    private let lock = DonkLock()
    private var handlers: [ObjectIdentifier: HTTPExchange] = [:]

    func register(_ task: URLSessionTask, _ exchange: HTTPExchange) {
        lock.withLock { handlers[ObjectIdentifier(task)] = exchange }
    }

    package var activeTaskCount: Int {
        lock.withLock { handlers.count }
    }

    private func handler(for task: URLSessionTask) -> HTTPExchange? {
        lock.withLock { handlers[ObjectIdentifier(task)] }
    }

    private func removeHandler(for task: URLSessionTask) -> HTTPExchange? {
        lock.withLock { handlers.removeValue(forKey: ObjectIdentifier(task)) }
    }

    // MARK: - URLSessionDataDelegate

    package func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let exchange = handler(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        exchange.innerDidReceive(response)
        completionHandler(.allow)
    }

    package func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.innerDidReceive(data)
    }

    package func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        guard let exchange = handler(for: dataTask) else {
            completionHandler(proposedResponse)
            return
        }
        exchange.innerWillCache(proposedResponse, completion: completionHandler)
    }

    // MARK: - URLSessionTaskDelegate

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let exchange = handler(for: task) else {
            completionHandler(nil)
            return
        }
        exchange.innerWillRedirect(response: response, newRequest: request, completion: completionHandler)
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let exchange = handler(for: task) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        exchange.innerDidReceive(challenge, completion: completionHandler)
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        handler(for: task)?.innerDidFinishCollecting(metrics)
    }

    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        removeHandler(for: task)?.innerDidComplete(error)
    }
}
