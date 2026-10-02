import Combine
import DonkCore
import DonkInspector
import DonkPerformance
import DonkUI
import SwiftUI
import UIKit

// MARK: - Model

struct BubbleFlash: Equatable {
    var id: Int
    var tone: DonkTone
}

enum BubbleQuickAction: Equatable {
    case inspector(InspectorMode)
    case stopInspector
    case toggleHUD
    case clearNetworkLog
    case hideBubble
}

@MainActor
final class BubbleModel: ObservableObject {
    @Published var unseen = 0
    @Published var flash: BubbleFlash?
    @Published var isPaused = false
    @Published var placement: BubblePlacement
    @Published var menuScene: ObjectIdentifier?
    @Published var isHiding = false
    @Published var inspectorMode: InspectorMode?
    @Published var isHUDVisible = false
    @Published var tools: Set<DonkTool> = Set(DonkTool.allCases)

    var isDebuggerVisible = false
    var onToggle: ((ObjectIdentifier) -> Void)?
    var onAction: ((BubbleQuickAction) -> Void)?
    var onFocusScene: ((ObjectIdentifier) -> Void)?

    private var flashCounter = 0

    init() {
        placement = DonkPreferencesStore.shared.value.bubble
    }

    func apply(_ activity: BubbleActivity) {
        if activity.cleared {
            unseen = 0
        }
        if activity.added > 0, !isDebuggerVisible {
            unseen += activity.added
        }
        if let tone = activity.tone {
            flashCounter &+= 1
            flash = BubbleFlash(id: flashCounter, tone: tone)
        }
    }

    func commit(_ placement: BubblePlacement) {
        self.placement = placement
        DonkPreferencesStore.shared.update { $0.bubble = placement }
    }

    func openMenu(in scene: ObjectIdentifier) {
        onFocusScene?(scene)
        inspectorMode = DonkInspector.activeMode
        isHUDVisible = DonkPerformance.isHUDVisible
        DonkHaptics.medium()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            menuScene = scene
        }
    }

    func closeMenu() {
        guard menuScene != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            menuScene = nil
        }
    }
}

// MARK: - Launcher

@MainActor
final class BubbleLauncher {
    typealias BubbleWindow = DonkHostingPassthroughWindow<BubbleRootView>

    let model = BubbleModel()

    private var windows: DonkSceneWindowSet<BubbleWindow>?
    private var monitor: BubbleActivityMonitor?
    private var breakpointSubscription: AnyCancellable?
    private var menuSubscription: AnyCancellable?
    private var hideWorkItem: DispatchWorkItem?
    private var isStarted = false
    private var isEnabled = false
    private var quickActionsWaiter: AnyCancellable?
    private(set) var isTemporarilyHidden = false

    init() {
        model.onToggle = { [weak self] sceneID in
            self?.focusScene(sceneID)
            DonkRuntime.shared.toggle()
        }
        model.onFocusScene = { [weak self] sceneID in
            self?.focusScene(sceneID)
        }
        model.onAction = { [weak self] action in
            self?.perform(action)
        }
        menuSubscription = model.$menuScene
            .removeDuplicates()
            .sink { [weak self] scene in
                MainActor.assumeIsolated { self?.updateTouchCapture(menuScene: scene) }
            }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let model = model
        let monitor = BubbleActivityMonitor { activity in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.apply(activity) }
            }
        }
        monitor.start()
        self.monitor = monitor
        breakpointSubscription = BreakpointCenter.shared.changes
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { isPaused in
                MainActor.assumeIsolated {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        model.isPaused = isPaused
                    }
                }
            }
        updateWindows(animated: false)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor?.stop()
        monitor = nil
        breakpointSubscription = nil
        isTemporarilyHidden = false
        quickActionsWaiter = nil
        model.menuScene = nil
        model.unseen = 0
        model.isPaused = false
        updateWindows(animated: false)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        updateWindows(animated: true)
    }

    func hideTemporarily() {
        guard !isTemporarilyHidden else { return }
        isTemporarilyHidden = true
        updateWindows(animated: true)
    }

    func restore() {
        guard isTemporarilyHidden else { return }
        isTemporarilyHidden = false
        updateWindows(animated: true)
    }

    func debuggerVisibilityChanged(_ isVisible: Bool) {
        model.isDebuggerVisible = isVisible
        if isVisible {
            model.unseen = 0
            model.closeMenu()
        }
    }

    func openQuickActions() {
        guard let scene = DonkWindowManager.activeWindowScene,
              scene.activationState == .foregroundActive,
              windows?.window(for: scene) != nil else {
            waitForSceneToOpenQuickActions()
            return
        }
        quickActionsWaiter = nil
        model.openMenu(in: ObjectIdentifier(scene))
    }

    func closeQuickActions() {
        quickActionsWaiter = nil
        model.closeMenu()
    }

    private func waitForSceneToOpenQuickActions() {
        guard quickActionsWaiter == nil else { return }
        quickActionsWaiter = DonkWindowManager.observeScenes { [weak self] event in
            guard let self, case .activated = event else { return }
            self.quickActionsWaiter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated {
                    guard self.shouldShow else { return }
                    self.openQuickActions()
                }
            }
        }
    }

    private func focusScene(_ sceneID: ObjectIdentifier) {
        let scene = windows?.windows.lazy.compactMap(\.windowScene).first { ObjectIdentifier($0) == sceneID }
        if let scene {
            DonkWindowManager.preferScene(scene)
        }
    }

    private func updateTouchCapture(menuScene: ObjectIdentifier?) {
        windows?.forEach { window in
            let captures = menuScene != nil && window.windowScene.map(ObjectIdentifier.init) == menuScene
            if window.capturesAllTouches != captures {
                window.capturesAllTouches = captures
            }
        }
    }

    private var shouldShow: Bool {
        isStarted && isEnabled && !isTemporarilyHidden
    }

    private func updateWindows(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if shouldShow {
            let set = windows ?? makeWindowSet()
            windows = set
            model.isHiding = false
            set.isActive = true
            return
        }
        guard let set = windows, set.isActive else { return }
        model.menuScene = nil
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            set.isActive = false
            return
        }
        withAnimation(.easeIn(duration: 0.18)) {
            model.isHiding = true
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shouldShow else { return }
                self.windows?.isActive = false
                self.model.isHiding = false
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func makeWindowSet() -> DonkSceneWindowSet<BubbleWindow> {
        let model = model
        let set = DonkSceneWindowSet<BubbleWindow> { scene in
            BubbleWindow(
                windowScene: scene,
                level: DonkWindowLevel.bubble,
                rootView: BubbleRootView(model: model, sceneID: ObjectIdentifier(scene))
            )
        }
        set.onWindowCreated = { [weak self] window in
            guard let self else { return }
            window.capturesAllTouches = self.model.menuScene != nil
                && window.windowScene.map(ObjectIdentifier.init) == self.model.menuScene
        }
        return set
    }

    // MARK: - Quick actions

    private func perform(_ action: BubbleQuickAction) {
        model.closeMenu()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.run(action) }
        }
    }

    private func run(_ action: BubbleQuickAction) {
        switch action {
        case let .inspector(mode):
            guard model.tools.contains(.inspector) else { return }
            if DonkInspector.activeMode == mode {
                DonkRuntime.shared.stopInspector()
            } else {
                DonkRuntime.shared.startInspector(mode)
            }
        case .stopInspector:
            DonkRuntime.shared.stopInspector()
        case .toggleHUD:
            guard model.tools.contains(.performance) else { return }
            let visible = !DonkPerformance.isHUDVisible
            DonkPerformance.isHUDVisible = visible
            DonkHaptics.light()
        case .clearNetworkLog:
            NetworkStore.shared.clear()
            DonkHaptics.success()
            DonkToast.show("Network log cleared", icon: "trash", tone: .success, duration: 1.6)
        case .hideBubble:
            DonkRuntime.shared.hideBubbleTemporarily()
        }
    }
}
