import DonkCore
import DonkUI
import ObjectiveC
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
        let selector = #selector(UIResponder.motionEnded(_:with:))
        guard let inherited = class_getInstanceMethod(UIWindow.self, selector) else { return }
        class_addMethod(UIWindow.self, selector, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        typealias MotionEnded = @convention(c) (UIWindow, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: MotionEnded.self)
        let replacement: @convention(block) (UIWindow, UIEvent.EventSubtype, UIEvent?) -> Void = { window, motion, event in
            original(window, selector, motion, event)
            guard motion == .motionShake else { return }
            MainActor.assumeIsolated {
                ShakeDetector.didShake(in: window.windowScene)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        isInstalled = true
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
