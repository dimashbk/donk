import Combine
import UIKit

// MARK: - Levels

public enum DonkWindowLevel {
    public static let inspector = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 100)
    public static let hud = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 200)
    public static let bubble = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 300)
    public static let debugger = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 400)
    public static let toast = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 500)
}

// MARK: - Marker

public protocol DonkWindowMarker: AnyObject {}

// MARK: - Scene events

public enum DonkSceneEvent {
    case connected(UIWindowScene)
    case activated(UIWindowScene)
    case deactivated(UIWindowScene)
    case enteredForeground(UIWindowScene)
    case enteredBackground(UIWindowScene)
    case disconnected(UIWindowScene)

    public var scene: UIWindowScene {
        switch self {
        case let .connected(scene), let .activated(scene), let .deactivated(scene),
             let .enteredForeground(scene), let .enteredBackground(scene), let .disconnected(scene):
            return scene
        }
    }
}

// MARK: - Manager

@MainActor
public enum DonkWindowManager {
    public static var windowScenes: [UIWindowScene] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.sorted { rank($0.activationState) < rank($1.activationState) }
    }

    public static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let preferred = preferredSceneReference.flatMap { scene in scenes.first { $0 === scene } }
        let keyScene = scenes.first { scene in scene.windows.contains { $0.isKeyWindow } }
        for state in [UIScene.ActivationState.foregroundActive, .foregroundInactive] {
            if let preferred, preferred.activationState == state { return preferred }
            if let keyScene, keyScene.activationState == state { return keyScene }
            if let first = scenes.first(where: { $0.activationState == state }) { return first }
        }
        return nil
    }

    public static var preferredScene: UIWindowScene? {
        preferredSceneReference
    }

    public static func preferScene(_ scene: UIWindowScene?) {
        preferredSceneReference = scene
    }

    private static weak var preferredSceneReference: UIWindowScene?

    public static var foregroundWindowScenes: [UIWindowScene] {
        windowScenes.filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
    }

    public static func isDonkWindow(_ window: UIWindow) -> Bool {
        window is DonkWindowMarker
    }

    public static var appWindows: [UIWindow] {
        appWindows(in: activeWindowScene)
    }

    public static func appWindows(in scene: UIWindowScene?) -> [UIWindow] {
        guard let scene else { return [] }
        return scene.windows.enumerated()
            .filter { !isDonkWindow($0.element) }
            .sorted { lhs, rhs in
                if lhs.element.windowLevel == rhs.element.windowLevel { return lhs.offset < rhs.offset }
                return lhs.element.windowLevel < rhs.element.windowLevel
            }
            .map(\.element)
    }

    public static var donkWindows: [UIWindow] {
        windowScenes.flatMap(\.windows).filter(isDonkWindow)
    }

    public static var appKeyWindow: UIWindow? {
        appKeyWindow(in: activeWindowScene)
    }

    public static func appKeyWindow(in scene: UIWindowScene?) -> UIWindow? {
        guard let scene else { return nil }
        if let key = scene.keyWindow, !isDonkWindow(key) { return key }
        if let debugger = debuggerWindow(in: scene),
           let previous = debugger.previousKeyWindow,
           previous.windowScene === scene, !previous.isHidden {
            return previous
        }
        let candidates = appWindows(in: scene).filter { !$0.isHidden && $0.alpha > 0.01 }
        return candidates.last { $0.windowLevel == .normal } ?? candidates.last
    }

    public static var debuggerWindow: DonkKeyWindow? {
        debuggerWindow(in: activeWindowScene)
    }

    public static func debuggerWindow(in scene: UIWindowScene?) -> DonkKeyWindow? {
        guard let scene else { return nil }
        return scene.windows.lazy.compactMap { $0 as? DonkKeyWindow }.first { !$0.isHidden }
    }

    public static func topViewController(in window: UIWindow?) -> UIViewController? {
        guard var controller = window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    public static var presentingViewController: UIViewController? {
        if let debugger = debuggerWindow, let controller = topViewController(in: debugger) {
            return controller
        }
        return topViewController(in: appKeyWindow)
    }

    public static func refreshSystemAppearance() {
        for window in donkWindows where !window.isHidden {
            (window.rootViewController as? DonkPassthroughRootViewController)?.refreshSystemAppearance()
        }
        if let root = appKeyWindow?.rootViewController {
            root.setNeedsStatusBarAppearanceUpdate()
            root.setNeedsUpdateOfHomeIndicatorAutoHidden()
            root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }

    // MARK: - Presentations

    public static func markDonkPresentation(_ controller: UIViewController) {
        ownedPresentations.add(controller)
    }

    public static func isDonkPresentation(_ controller: UIViewController) -> Bool {
        if ownedPresentations.contains(controller) { return true }
        return isDonkTypeName(String(reflecting: type(of: controller)))
    }

    public static func presentationChain(above controller: UIViewController) -> [UIViewController] {
        var chain: [UIViewController] = []
        var current = controller.presentedViewController
        while let next = current, chain.count < 32 {
            chain.append(next)
            current = next.presentedViewController
        }
        return chain
    }

    public static func firstForeignPresentation(above controller: UIViewController) -> UIViewController? {
        presentationChain(above: controller).first { !isDonkPresentation($0) }
    }

    static func isDonkTypeName(_ name: String) -> Bool {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.")).inverted
        let modules = name.components(separatedBy: separators).compactMap { token -> String? in
            guard let dot = token.firstIndex(of: "."), dot != token.startIndex else { return nil }
            return String(token[..<dot])
        }
        guard !modules.isEmpty else { return false }
        return modules.allSatisfy { module in
            module.hasPrefix("Donk") || frameworkModules.contains(module)
        }
    }

    private static let frameworkModules: Set<String> = ["SwiftUI", "Swift", "UIKit", "UIKitCore", "Foundation", "Combine"]

    private static let ownedPresentations = NSHashTable<UIViewController>.weakObjects()

    public static var sceneEvents: AnyPublisher<DonkSceneEvent, Never> {
        let center = NotificationCenter.default
        func events(
            _ name: Notification.Name,
            _ make: @escaping (UIWindowScene) -> DonkSceneEvent
        ) -> AnyPublisher<DonkSceneEvent, Never> {
            center.publisher(for: name)
                .compactMap { ($0.object as? UIWindowScene).map(make) }
                .eraseToAnyPublisher()
        }
        return Publishers.MergeMany([
            events(UIScene.willConnectNotification, DonkSceneEvent.connected),
            events(UIScene.didActivateNotification, DonkSceneEvent.activated),
            events(UIScene.willDeactivateNotification, DonkSceneEvent.deactivated),
            events(UIScene.willEnterForegroundNotification, DonkSceneEvent.enteredForeground),
            events(UIScene.didEnterBackgroundNotification, DonkSceneEvent.enteredBackground),
            events(UIScene.didDisconnectNotification, DonkSceneEvent.disconnected),
        ])
        .eraseToAnyPublisher()
    }

    public static func observeScenes(_ handler: @escaping @MainActor (DonkSceneEvent) -> Void) -> AnyCancellable {
        sceneEvents.sink { event in
            DonkMain.run { handler(event) }
        }
    }

    private static func rank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: return 0
        case .foregroundInactive: return 1
        case .background: return 2
        case .unattached: return 3
        @unknown default: return 4
        }
    }
}

// MARK: - Per-scene windows

@MainActor
public final class DonkSceneWindowSet<Window: UIWindow> {
    private let factory: @MainActor (UIWindowScene) -> Window
    private var storage: [ObjectIdentifier: Window] = [:]
    private var cancellable: AnyCancellable?

    public var onWindowCreated: (@MainActor (Window) -> Void)?

    public var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? activate() : deactivate()
        }
    }

    public init(_ factory: @escaping @MainActor (UIWindowScene) -> Window) {
        self.factory = factory
    }

    public var windows: [Window] {
        Array(storage.values)
    }

    public var activeWindow: Window? {
        guard let scene = DonkWindowManager.activeWindowScene else { return nil }
        return storage[ObjectIdentifier(scene)]
    }

    public func window(for scene: UIWindowScene) -> Window? {
        storage[ObjectIdentifier(scene)]
    }

    @discardableResult
    public func ensureWindow(for scene: UIWindowScene) -> Window {
        if let existing = storage[ObjectIdentifier(scene)] {
            existing.isHidden = false
            return existing
        }
        let window = factory(scene)
        storage[ObjectIdentifier(scene)] = window
        window.isHidden = false
        onWindowCreated?(window)
        return window
    }

    public func forEach(_ body: (Window) -> Void) {
        storage.values.forEach(body)
    }

    public func removeAll() {
        storage.values.forEach { window in
            window.isHidden = true
            window.windowScene = nil
        }
        storage.removeAll()
    }

    private func activate() {
        DonkWindowManager.foregroundWindowScenes.forEach { ensureWindow(for: $0) }
        cancellable = DonkWindowManager.observeScenes { [weak self] event in
            self?.handle(event)
        }
    }

    private func deactivate() {
        cancellable = nil
        removeAll()
    }

    private func handle(_ event: DonkSceneEvent) {
        guard isActive else { return }
        switch event {
        case let .connected(scene), let .activated(scene), let .enteredForeground(scene):
            ensureWindow(for: scene)
        case let .disconnected(scene):
            if let window = storage.removeValue(forKey: ObjectIdentifier(scene)) {
                window.isHidden = true
                window.windowScene = nil
            }
        case .deactivated, .enteredBackground:
            break
        }
    }
}

// MARK: - Main thread

enum DonkMain {
    static func run(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { work() }
        }
    }
}
