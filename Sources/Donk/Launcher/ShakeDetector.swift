import DonkCore
import DonkUI
import UIKit

@MainActor
enum ShakeDetector {
    static var handler: (@MainActor () -> Void)?
    static var isEnabled = false

    private static var isInstalled = false
    private static var lastShake: Date = .distantPast
    private static let debounce: TimeInterval = 0.6

    static func install() {
        guard !isInstalled else { return }
        isInstalled = DonkSwizzle.instanceMethod(
            UIWindow.self,
            #selector(UIResponder.motionEnded(_:with:)),
            #selector(UIWindow.donk_motionEnded(_:with:))
        )
    }

    fileprivate static func didShake(in scene: UIWindowScene?) {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastShake) > debounce else { return }
        lastShake = now
        if let scene {
            DonkWindowManager.preferScene(scene)
        }
        handler?()
    }
}

extension UIWindow {
    @objc dynamic func donk_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        donk_motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        ShakeDetector.didShake(in: windowScene)
    }
}
