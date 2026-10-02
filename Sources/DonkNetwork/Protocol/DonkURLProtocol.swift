import DonkCore
import Foundation
import ObjectiveC.runtime

class DonkURLProtocol: URLProtocol {
    static let handledKey = "dev.donk.network.handled"

    private var exchange: HTTPExchange?

    override class func canInit(with request: URLRequest) -> Bool {
        let streamed = request.httpBody == nil && request.httpBodyStream != nil
        return CaptureEngine.shared.shouldIntercept(request, passesThroughUnlessRuled: streamed)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        if task is URLSessionWebSocketTask || task is URLSessionStreamTask { return false }
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        let upload = task is URLSessionUploadTask || task.originalRequest?.httpBodyStream != nil
        return CaptureEngine.shared.shouldIntercept(request, passesThroughUnlessRuled: upload)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let context = SessionContextRegistry.shared.context(for: object_getClass(self) ?? DonkURLProtocol.self)
        let exchange = HTTPExchange(
            urlProtocol: self,
            request: request,
            context: context,
            environment: CaptureEngine.shared.environment,
            channel: ClientChannel()
        )
        self.exchange = exchange
        exchange.start()
    }

    override func stopLoading() {
        exchange?.stop()
        exchange = nil
    }
}
