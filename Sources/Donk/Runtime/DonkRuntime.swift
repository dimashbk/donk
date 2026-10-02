import Combine
import DonkCore
import DonkInspector
import DonkUI
import UIKit

@MainActor
final class DonkRuntime {
    static let shared = DonkRuntime()

    let debugger = DebuggerPresenter()
    let launcher = BubbleLauncher()
    let breakpoints = BreakpointCoordinator()

    private(set) var isStarted = false
    private var configuration = DonkConfiguration()
    private var preferencesSubscription: AnyCancellable?

    private init() {
        debugger.onVisibilityChange = { [weak self] isVisible in
            self?.launcher.debuggerVisibilityChanged(isVisible)
        }
        debugger.router.canShow = { [weak self] tool in
            self?.isToolEnabled(tool) ?? true
        }
        ShakeDetector.handler = { [weak self] in
            self?.handleShake()
        }
    }

    // MARK: - Lifecycle

    func start(_ configuration: DonkConfiguration, token: Int) {
        guard DonkEngine.shared.isCurrent(token), !isStarted else { return }
        isStarted = true
        self.configuration = configuration
        launcher.model.tools = configuration.tools
        debugger.home.tools = configuration.tools
        debugger.router.clearUnavailableRoute()
        ShakeDetector.install()
        ShakeDetector.isEnabled = true
        DonkInspector.onWillStart = { [weak self] in
            self?.debugger.hide(animated: false)
        }
        DonkInspector.onOpenDebugger = { [weak self] in
            self?.show(nil)
        }
        DonkEnvironment.hideDebuggerHandler = { [weak self] in
            self?.debugger.hide(animated: false)
        }
        launcher.start()
        breakpoints.start()
        preferencesSubscription = DonkPreferencesStore.shared.changes
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyLauncherPreferences() }
            }
        applyLauncherPreferences()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        preferencesSubscription = nil
        ShakeDetector.isEnabled = false
        breakpoints.stop()
        launcher.stop()
        DonkInspector.onWillStart = nil
        DonkInspector.onOpenDebugger = nil
        DonkEnvironment.hideDebuggerHandler = nil
        debugger.hide(animated: false)
        if DonkInspector.activeMode != nil {
            DonkInspector.stop()
        }
    }

    // MARK: - Tools

    var tools: Set<DonkTool> {
        configuration.tools
    }

    func isToolEnabled(_ tool: DonkTool) -> Bool {
        configuration.tools.contains(tool)
    }

    // MARK: - Launcher

    var showsBubble: Bool {
        DonkPreferencesStore.shared.value.showsBubble ?? configuration.showsBubble
    }

    var opensOnShake: Bool {
        DonkPreferencesStore.shared.value.opensOnShake ?? configuration.opensOnShake
    }

    var defaultShowsBubble: Bool {
        configuration.showsBubble
    }

    var defaultOpensOnShake: Bool {
        configuration.opensOnShake
    }

    private func applyLauncherPreferences() {
        launcher.setEnabled(isStarted && showsBubble)
    }

    func hideBubbleTemporarily() {
        launcher.hideTemporarily()
        if opensOnShake {
            DonkToast.show("Bubble hidden — shake to bring it back", icon: "eye.slash", duration: 2.6)
        } else {
            DonkToast.show("Bubble hidden until the next launch", icon: "eye.slash", duration: 2.6)
        }
    }

    func showQuickActions() {
        guard isStarted, showsBubble else { return }
        if launcher.isTemporarilyHidden {
            launcher.restore()
        }
        debugger.hide()
        launcher.openQuickActions()
    }

    private func handleShake() {
        guard isStarted, opensOnShake else { return }
        if launcher.isTemporarilyHidden, showsBubble {
            launcher.restore()
            DonkHaptics.success()
            return
        }
        toggle()
    }

    // MARK: - Debugger

    func show(_ tool: DonkTool?) {
        launcher.closeQuickActions()
        debugger.show(tool: tool)
    }

    func hide() {
        debugger.hide()
    }

    func toggle() {
        let scene = DonkWindowManager.activeWindowScene
        if debugger.isVisible, scene == nil || debugger.windowScene === scene {
            hide()
        } else {
            show(nil)
        }
    }

    // MARK: - Inspector

    func startInspector(_ mode: InspectorMode) {
        guard isToolEnabled(.inspector) else { return }
        launcher.closeQuickActions()
        if debugger.isVisible {
            debugger.hide {
                DonkInspector.start(mode)
            }
        } else {
            DonkInspector.start(mode)
        }
    }

    func stopInspector() {
        DonkInspector.stop()
    }
}
