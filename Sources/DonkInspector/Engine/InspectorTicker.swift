import QuartzCore
import UIKit

@MainActor
final class InspectorTicker {
    private var link: CADisplayLink?
    private var handler: (@MainActor () -> Void)?
    private var lastFire: CFTimeInterval = 0
    private let interval: CFTimeInterval

    init(framesPerSecond: Double = 6) {
        interval = 1 / framesPerSecond
    }

    var isRunning: Bool {
        link != nil
    }

    func start(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        guard link == nil else { return }
        let proxy = TickerProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(TickerProxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 6)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        handler = nil
    }

    fileprivate func step(_ timestamp: CFTimeInterval) {
        guard timestamp - lastFire >= interval * 0.85 else { return }
        lastFire = timestamp
        handler?()
    }
}

private final class TickerProxy: NSObject {
    weak var owner: InspectorTicker?

    @objc func step(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        MainActor.assumeIsolated {
            owner?.step(timestamp)
        }
    }
}
