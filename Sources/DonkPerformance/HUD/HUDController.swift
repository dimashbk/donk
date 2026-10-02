import Combine
import DonkUI
import SwiftUI
import UIKit

// MARK: - Model

@MainActor
final class HUDModel: ObservableObject {
    @Published private(set) var sample: PerformanceSample?
    @Published private(set) var isExpanded: Bool
    @Published private(set) var edge: HUDEdge
    @Published private(set) var verticalFraction: Double
    @Published private(set) var keyboardOverlap: CGFloat = 0

    private let monitor: PerformanceMonitor
    private var cancellable: AnyCancellable?

    init(monitor: PerformanceMonitor = .shared) {
        self.monitor = monitor
        let prefs = monitor.preferences.value
        isExpanded = prefs.isHUDExpanded
        edge = prefs.hudEdge
        verticalFraction = prefs.hudVerticalFraction
    }

    func activate() {
        sample = monitor.latestSample
        guard cancellable == nil else { return }
        cancellable = monitor.updates
            .compactMap { update -> PerformanceSample?? in
                switch update {
                case let .sample(sample): return .some(sample)
                case .reset: return .some(nil)
                case .events, .state: return nil
                }
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sample in
                self?.sample = sample
            }
    }

    func deactivate() {
        cancellable = nil
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            isExpanded = expanded
        }
        DonkHaptics.light()
        monitor.preferences.update { $0.isHUDExpanded = expanded }
    }

    func setKeyboardOverlap(_ overlap: CGFloat) {
        let value = max(0, overlap.rounded())
        guard value != keyboardOverlap else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            keyboardOverlap = value
        }
    }

    func move(to edge: HUDEdge, verticalFraction: Double) {
        let fraction = min(max(verticalFraction, 0), 1)
        self.edge = edge
        self.verticalFraction = fraction
        monitor.preferences.update {
            $0.hudEdge = edge
            $0.hudVerticalFraction = fraction
        }
    }
}

// MARK: - Controller

@MainActor
final class HUDController {
    static let shared = HUDController()

    let model = HUDModel()
    private(set) var isKeyboardRaised = false
    private var windows: DonkSceneWindowSet<DonkHostingPassthroughWindow<HUDRootView>>?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var isKeyboardVisible = false
    private var keyboardFrame: CGRect?

    private static let keyboardLevel = UIWindow.Level(rawValue: 10_000_000)

    var isVisible: Bool {
        windows?.isActive ?? false
    }

    var activeWindows: [UIWindow] {
        windows?.windows ?? []
    }

    func monitorDidStart() {
        setVisible(PerformanceMonitor.shared.preferences.value.isHUDVisible)
    }

    func monitorDidStop() {
        setVisible(false)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            let set = windows ?? makeWindowSet()
            windows = set
            model.activate()
            set.isActive = true
            observeKeyboard()
            updateLevels()
        } else {
            windows?.isActive = false
            model.deactivate()
            stopObservingKeyboard()
        }
    }

    private func makeWindowSet() -> DonkSceneWindowSet<DonkHostingPassthroughWindow<HUDRootView>> {
        let model = model
        let set = DonkSceneWindowSet<DonkHostingPassthroughWindow<HUDRootView>> { scene in
            let window = DonkHostingPassthroughWindow(windowScene: scene, level: DonkWindowLevel.hud, rootView: HUDRootView(model: model))
            window.accessibilityIdentifier = "donk.performance.hud"
            return window
        }
        set.onWindowCreated = { [weak self] _ in
            self?.updateLevels()
        }
        return set
    }

    // MARK: - Keyboard

    var staysAboveKeyboard: Bool {
        PerformanceMonitor.shared.preferences.value.hudStaysAboveKeyboard
    }

    func setStaysAboveKeyboard(_ enabled: Bool) {
        PerformanceMonitor.shared.preferences.update { $0.hudStaysAboveKeyboard = enabled }
        updateLevels(bringsToFront: enabled)
    }

    private func observeKeyboard() {
        guard keyboardObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let willShow: @Sendable (Notification) -> Void = { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            PerformanceMain.run {
                self?.keyboardFrame = frame
                self?.isKeyboardVisible = true
                self?.updateLevels(bringsToFront: false)
            }
        }
        let didShow: @Sendable (Notification) -> Void = { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            PerformanceMain.run {
                self?.keyboardFrame = frame
                self?.isKeyboardVisible = true
                self?.updateLevels(bringsToFront: true)
            }
        }
        let willHide: @Sendable (Notification) -> Void = { [weak self] _ in
            PerformanceMain.run {
                self?.keyboardFrame = nil
                self?.isKeyboardVisible = false
                self?.updateLevels(bringsToFront: false)
            }
        }
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main, using: willShow),
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main, using: willShow),
            center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main, using: didShow),
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main, using: willHide),
        ]
    }

    private func stopObservingKeyboard() {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers = []
        isKeyboardVisible = false
        isKeyboardRaised = false
        keyboardFrame = nil
        model.setKeyboardOverlap(0)
    }

    static func overlap(of keyboard: CGRect?, in window: UIWindow) -> CGFloat {
        guard let keyboard, !keyboard.isEmpty else { return 0 }
        let local = window.convert(keyboard, from: window.screen.coordinateSpace)
        guard local.intersects(window.bounds) else { return 0 }
        return max(0, window.bounds.maxY - local.minY)
    }

    private func updateLevels(bringsToFront: Bool = false) {
        guard let windows else { return }
        let raise = isKeyboardVisible && staysAboveKeyboard && DonkWindowManager.debuggerWindow == nil
        isKeyboardRaised = raise
        var overlap: CGFloat = 0
        windows.forEach { window in
            let level = raise ? Self.keyboardLevel : DonkWindowLevel.hud
            if window.windowLevel != level {
                window.windowLevel = level
            }
            if raise {
                overlap = max(overlap, Self.overlap(of: keyboardFrame, in: window))
            }
            if raise, bringsToFront, !window.isHidden {
                window.isHidden = true
                window.isHidden = false
            }
        }
        model.setKeyboardOverlap(raise ? overlap : 0)
    }
}
