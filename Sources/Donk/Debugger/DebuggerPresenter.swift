import Combine
import DonkCore
import DonkInspector
import DonkUI
import os
import SwiftUI
import UIKit

// MARK: - Router

@MainActor
final class DebuggerRouter: ObservableObject {
    @Published var route: DonkTool?

    var canShow: @MainActor (DonkTool) -> Bool = { _ in true }

    private var pendingRoute: DispatchWorkItem?

    func open(_ tool: DonkTool?) {
        if let tool, !canShow(tool) {
            DonkLog.debugger.notice("donk: \(tool.rawValue, privacy: .public) is disabled in DonkConfiguration.tools, ignoring the route")
            clearUnavailableRoute()
            return
        }
        pendingRoute?.cancel()
        pendingRoute = nil
        guard route != tool else { return }
        guard route != nil, tool != nil else {
            route = tool
            return
        }
        route = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRoute = nil
                if let tool, self.canShow(tool) {
                    self.route = tool
                }
            }
        }
        pendingRoute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func clearUnavailableRoute() {
        guard let route, !canShow(route) else { return }
        pendingRoute?.cancel()
        pendingRoute = nil
        self.route = nil
    }

    func binding(for tool: DonkTool) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                guard let self, self.route == tool else { return false }
                return self.canShow(tool)
            },
            set: { [weak self] isActive in
                guard let self else { return }
                if isActive {
                    self.route = tool
                } else if self.route == tool {
                    self.route = nil
                }
            }
        )
    }
}

// MARK: - Presenter

@MainActor
final class DebuggerPresenter {
    let router = DebuggerRouter()
    let home = HomeModel()

    private var isShowing = false
    var onVisibilityChange: ((Bool) -> Void)?

    private var window: DonkKeyWindow?
    private var container: DebuggerContainerController?
    private var transitionToken = 0
    private var pendingShow: [() -> Void] = []
    private var sceneObservation: AnyCancellable?
    private var inspectorTimer: Timer?
    private var lastInspectorMode: InspectorMode?

    var isVisible: Bool {
        guard isShowing, let window else { return false }
        return !window.isHidden
    }

    var presentingController: UIViewController? {
        guard isVisible, let window else { return nil }
        return DonkWindowManager.topViewController(in: window)
    }

    var windowScene: UIWindowScene? {
        isVisible ? window?.windowScene : nil
    }

    func show(tool: DonkTool?, completion: (() -> Void)? = nil) {
        if let tool {
            router.open(tool)
        } else {
            router.clearUnavailableRoute()
        }
        if isVisible {
            if let window, let scene = DonkWindowManager.activeWindowScene, window.windowScene !== scene {
                window.windowScene = scene
            }
            completion?()
            return
        }
        guard let scene = DonkWindowManager.activeWindowScene else {
            deferShow { [weak self] in self?.show(tool: nil, completion: completion) }
            return
        }
        let window = window(for: scene)
        isShowing = true
        transitionToken &+= 1
        let token = transitionToken
        home.setActive(true)
        DonkEnvironment.setDebuggerVisible(true)
        onVisibilityChange?(true)
        startInspectorWatch()
        window.present()
        container?.animateIn { [weak self] in
            guard let self, self.transitionToken == token else { return }
            completion?()
        }
    }

    func hide(animated: Bool = true, completion: (() -> Void)? = nil) {
        pendingShow.removeAll()
        guard isShowing, let window else {
            completion?()
            return
        }
        let wasVisible = !window.isHidden
        isShowing = false
        transitionToken &+= 1
        let token = transitionToken
        home.setActive(false)
        DonkEnvironment.setDebuggerVisible(false)
        onVisibilityChange?(false)
        stopInspectorWatch()
        let finish = { [weak self] in
            guard let self, self.transitionToken == token else { return }
            window.dismiss()
            DonkWindowManager.refreshSystemAppearance()
            completion?()
        }
        let close = { [weak self] in
            guard let self, self.transitionToken == token else { return }
            if animated, wasVisible {
                self.container?.animateOut(completion: finish)
            } else {
                self.container?.resetAppearance()
                finish()
            }
        }
        dismissForeignPresentations(animated: animated && wasVisible, completion: close)
    }

    // MARK: - Foreign presentations

    private func dismissForeignPresentations(animated: Bool, completion: @escaping () -> Void) {
        guard let container, let foreign = DonkWindowManager.firstForeignPresentation(above: container) else {
            completion()
            return
        }
        let name = String(reflecting: type(of: foreign))
        DonkLog.debugger.error(
            "donk: \(name, privacy: .public) was presented on the debugger window by code outside donk. Dismissing it before donk hides; present host UI from the app's own window (for example a key-window lookup that skips DonkWindowMarker windows)."
        )
        guard let presenter = foreign.presentingViewController else {
            completion()
            return
        }
        presenter.dismiss(animated: animated) {
            MainActor.assumeIsolated { completion() }
        }
    }

    // MARK: - Window

    private func window(for scene: UIWindowScene) -> DonkKeyWindow {
        if let window {
            if window.windowScene !== scene {
                window.windowScene = scene
            }
            return window
        }
        let root = DebuggerRootView(router: router, home: home)
        let container = DebuggerContainerController(rootView: root)
        let window = DonkKeyWindow(windowScene: scene, level: DonkWindowLevel.debugger, rootViewController: container)
        window.backgroundColor = .clear
        self.window = window
        self.container = container
        return window
    }

    private func deferShow(_ action: @escaping () -> Void) {
        pendingShow.append(action)
        guard sceneObservation == nil else { return }
        sceneObservation = DonkWindowManager.observeScenes { [weak self] event in
            guard let self else { return }
            switch event {
            case .activated, .enteredForeground, .connected:
                guard DonkWindowManager.activeWindowScene != nil else { return }
                self.sceneObservation = nil
                let actions = self.pendingShow
                self.pendingShow.removeAll()
                DispatchQueue.main.async {
                    actions.forEach { $0() }
                }
            default:
                break
            }
        }
    }

    // MARK: - Inspector watch

    private func startInspectorWatch() {
        lastInspectorMode = DonkInspector.activeMode
        inspectorTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInspector() }
        }
        RunLoop.main.add(timer, forMode: .common)
        inspectorTimer = timer
    }

    private func stopInspectorWatch() {
        inspectorTimer?.invalidate()
        inspectorTimer = nil
    }

    private func checkInspector() {
        let mode = DonkInspector.activeMode
        defer { lastInspectorMode = mode }
        guard isVisible, let mode, mode != lastInspectorMode else { return }
        hide()
    }
}

// MARK: - Log

enum DonkLog {
    static let debugger = Logger(subsystem: "dev.donk", category: "debugger")
}

// MARK: - Container

@MainActor
final class DebuggerContainerController: UIViewController {
    private let hosting: UIHostingController<DebuggerRootView>

    init(rootView: DebuggerRootView) {
        hosting = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.view.backgroundColor = .systemGroupedBackground
        hosting.view.layer.cornerCurve = .continuous
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    override var childForStatusBarStyle: UIViewController? {
        hosting
    }

    override var childForStatusBarHidden: UIViewController? {
        hosting
    }

    func animateIn(completion: @escaping () -> Void) {
        loadViewIfNeeded()
        let content = hosting.view!
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let offset = max(view.bounds.height, 1) * 0.18
        if content.alpha > 0.99, content.transform == .identity {
            content.alpha = 0
            content.transform = reduceMotion ? .identity : CGAffineTransform(translationX: 0, y: offset).scaledBy(x: 0.98, y: 0.98)
        }
        content.layer.cornerRadius = reduceMotion ? 0 : 32
        content.clipsToBounds = true
        UIView.animate(
            withDuration: reduceMotion ? 0.2 : 0.48,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.2,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            content.alpha = 1
            content.transform = .identity
        } completion: { _ in
            content.layer.cornerRadius = 0
            content.clipsToBounds = false
            completion()
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    func animateOut(completion: @escaping () -> Void) {
        let content = hosting.view!
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let offset = max(view.bounds.height, 1) * 0.14
        content.layer.cornerRadius = reduceMotion ? 0 : 32
        content.clipsToBounds = true
        UIView.animate(
            withDuration: reduceMotion ? 0.18 : 0.26,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn]
        ) {
            content.alpha = 0
            if !reduceMotion {
                content.transform = CGAffineTransform(translationX: 0, y: offset).scaledBy(x: 0.98, y: 0.98)
            }
        } completion: { _ in
            completion()
        }
    }

    func resetAppearance() {
        let content = hosting.view!
        content.layer.removeAllAnimations()
        content.transform = .identity
        content.alpha = 1
        content.layer.cornerRadius = 0
        content.clipsToBounds = false
    }
}
