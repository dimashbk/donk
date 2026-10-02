import DonkCore
import Foundation
import ObjectiveC.runtime

package final class CacheDecision: @unchecked Sendable {
    private let lock = DonkLock()
    private var completion: ((CachedURLResponse?) -> Void)?

    package init(_ completion: @escaping (CachedURLResponse?) -> Void) {
        self.completion = completion
    }

    package func complete(_ response: CachedURLResponse?) {
        let handler: ((CachedURLResponse?) -> Void)? = lock.withLock {
            defer { completion = nil }
            return completion
        }
        handler?(response)
    }
}

package struct OuterCacheDelegate {
    package static let selector = NSSelectorFromString("URLSession:dataTask:willCacheResponse:completionHandler:")

    let session: URLSession
    let task: URLSessionDataTask
    let delegate: URLSessionDataDelegate
    let queue: OperationQueue

    package static func target(session: URLSession?, task: URLSessionTask?) -> OuterCacheDelegate? {
        guard let session, let task = task as? URLSessionDataTask else { return nil }
        if let delegate = task.delegate as? URLSessionDataDelegate, delegate.responds(to: selector) {
            return OuterCacheDelegate(session: session, task: task, delegate: delegate, queue: session.delegateQueue)
        }
        if let delegate = session.delegate as? URLSessionDataDelegate, delegate.responds(to: selector) {
            return OuterCacheDelegate(session: session, task: task, delegate: delegate, queue: session.delegateQueue)
        }
        return nil
    }

    func ask(_ proposed: CachedURLResponse, completion: @escaping (CachedURLResponse?) -> Void) {
        let target = self
        queue.addOperation {
            typealias Handler = @convention(block) (CachedURLResponse?) -> Void
            typealias Method = @convention(c) (AnyObject, Selector, URLSession, URLSessionDataTask, CachedURLResponse, Handler) -> Void
            guard let cls = object_getClass(target.delegate), let implementation = class_getMethodImplementation(cls, Self.selector) else {
                completion(proposed)
                return
            }
            let method = unsafeBitCast(implementation, to: Method.self)
            let handler: Handler = { completion($0) }
            method(target.delegate, Self.selector, target.session, target.task, proposed, handler)
        }
    }
}

package enum OuterRedirectPolicy {
    package static let selector = NSSelectorFromString("URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:")

    package static func asksDelegate(session: URLSession?, task: URLSessionTask?) -> Bool {
        guard let task else { return false }
        if let delegate = task.delegate, delegate.responds(to: selector) { return true }
        if let delegate = session?.delegate, delegate.responds(to: selector) { return true }
        return false
    }
}
