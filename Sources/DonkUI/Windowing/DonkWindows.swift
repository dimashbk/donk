import SwiftUI
import UIKit

// MARK: - Passthrough root controller

open class DonkPassthroughRootViewController: UIViewController {
    open override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        self.view = view
    }

    open override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let controller = appController(followingChild: \.childForStatusBarStyle) else {
            return Self.resolvedStatusBarStyle(.default, interfaceStyle: appWindow?.traitCollection.userInterfaceStyle ?? .unspecified)
        }
        return Self.resolvedStatusBarStyle(controller.preferredStatusBarStyle, interfaceStyle: interfaceStyle(of: controller))
    }

    open override var prefersStatusBarHidden: Bool {
        appController(followingChild: \.childForStatusBarHidden)?.prefersStatusBarHidden ?? false
    }

    open override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        .fade
    }

    open override var prefersHomeIndicatorAutoHidden: Bool {
        appController(followingChild: \.childForHomeIndicatorAutoHidden)?.prefersHomeIndicatorAutoHidden ?? false
    }

    open override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        appController(followingChild: \.childForScreenEdgesDeferringSystemGestures)?.preferredScreenEdgesDeferringSystemGestures ?? []
    }

    open override var childForStatusBarStyle: UIViewController? {
        nil
    }

    open override var childForStatusBarHidden: UIViewController? {
        nil
    }

    open override var childForHomeIndicatorAutoHidden: UIViewController? {
        nil
    }

    open override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
        nil
    }

    open override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard let controller = DonkWindowManager.topViewController(in: appWindow),
              controller !== self else { return .all }
        return controller.supportedInterfaceOrientations
    }

    public func refreshSystemAppearance() {
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    public static func resolvedStatusBarStyle(_ style: UIStatusBarStyle, interfaceStyle: UIUserInterfaceStyle) -> UIStatusBarStyle {
        guard style == .default else { return style }
        switch interfaceStyle {
        case .dark: return .lightContent
        case .light: return .darkContent
        case .unspecified: return .default
        @unknown default: return .default
        }
    }

    private var appWindow: UIWindow? {
        DonkWindowManager.appKeyWindow(in: view.window?.windowScene ?? DonkWindowManager.activeWindowScene)
    }

    private func interfaceStyle(of controller: UIViewController) -> UIUserInterfaceStyle {
        let style = controller.traitCollection.userInterfaceStyle
        if style != .unspecified { return style }
        return controller.viewIfLoaded?.window?.traitCollection.userInterfaceStyle
            ?? appWindow?.traitCollection.userInterfaceStyle
            ?? .unspecified
    }

    private func appController(followingChild child: KeyPath<UIViewController, UIViewController?>) -> UIViewController? {
        guard var controller = DonkWindowManager.topViewController(in: appWindow) else { return nil }
        var hops = 0
        while let next = controller[keyPath: child], next !== controller, hops < 12 {
            controller = next
            hops += 1
        }
        return controller === self ? nil : controller
    }
}

// MARK: - Passthrough window

open class DonkPassthroughWindow: UIWindow, DonkWindowMarker {
    public var capturesAllTouches = false
    public var interactionTest: ((CGPoint, UIView) -> Bool)?
    private let interactiveViewTable = NSHashTable<UIView>.weakObjects()

    public override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        configurePassthrough()
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configurePassthrough()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePassthrough()
    }

    public convenience init(windowScene: UIWindowScene, level: UIWindow.Level, rootViewController: UIViewController? = nil) {
        self.init(windowScene: windowScene)
        windowLevel = level
        self.rootViewController = rootViewController ?? DonkPassthroughRootViewController()
    }

    private func configurePassthrough() {
        backgroundColor = .clear
        isOpaque = false
    }

    open override var canBecomeKey: Bool {
        false
    }

    open override var isHidden: Bool {
        didSet {
            guard oldValue, !isHidden else { return }
            (rootViewController as? DonkPassthroughRootViewController)?.refreshSystemAppearance()
        }
    }

    public var interactiveViews: [UIView] {
        interactiveViewTable.allObjects
    }

    public func addInteractiveView(_ view: UIView) {
        interactiveViewTable.add(view)
    }

    public func removeInteractiveView(_ view: UIView) {
        interactiveViewTable.remove(view)
    }

    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if capturesAllTouches { return hit }
        return shouldReceiveTouch(at: point, hitView: hit) ? hit : nil
    }

    open func shouldReceiveTouch(at point: CGPoint, hitView: UIView) -> Bool {
        if let interactionTest, interactionTest(point, hitView) { return true }
        for view in interactiveViewTable.allObjects where !view.isHidden && view.window === self {
            if hitView === view || hitView.isDescendant(of: view) { return true }
        }
        return false
    }
}

// MARK: - SwiftUI passthrough window

open class DonkHostingPassthroughWindow<Content: View>: DonkPassthroughWindow {
    private let regions = DonkInteractiveRegions()
    private var hostingController: UIHostingController<DonkInteractiveRoot<Content>>?

    public init(windowScene: UIWindowScene, level: UIWindow.Level, rootView: Content) {
        super.init(windowScene: windowScene)
        windowLevel = level
        let root = DonkPassthroughRootViewController()
        let hosting = UIHostingController(rootView: DonkInteractiveRoot(content: rootView, regions: regions))
        hosting.view.backgroundColor = .clear
        hosting.view.isOpaque = false
        root.loadViewIfNeeded()
        root.addChild(hosting)
        hosting.view.frame = root.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(hosting.view)
        hosting.didMove(toParent: root)
        rootViewController = root
        hostingController = hosting
    }

    public override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public var rootView: Content? {
        get { hostingController?.rootView.content }
        set {
            guard let newValue else { return }
            hostingController?.rootView = DonkInteractiveRoot(content: newValue, regions: regions)
        }
    }

    public var hostingView: UIView? {
        hostingController?.view
    }

    public var interactiveRegions: [CGRect] {
        regions.rects
    }

    open override func shouldReceiveTouch(at point: CGPoint, hitView: UIView) -> Bool {
        if regions.contains(point) { return true }
        return super.shouldReceiveTouch(at: point, hitView: hitView)
    }
}

// MARK: - Interactive regions

final class DonkInteractiveRegions {
    var rects: [CGRect] = []

    func contains(_ point: CGPoint) -> Bool {
        rects.contains { $0.contains(point) }
    }
}

struct DonkInteractiveRegionsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

struct DonkInteractiveRoot<Content: View>: View {
    let content: Content
    let regions: DonkInteractiveRegions

    var body: some View {
        content.onPreferenceChange(DonkInteractiveRegionsKey.self) { [regions] rects in
            regions.rects = rects
        }
    }
}

public extension View {
    func donkInteractive(_ isEnabled: Bool = true, padding: CGFloat = 0) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DonkInteractiveRegionsKey.self,
                    value: isEnabled ? [proxy.frame(in: .global).insetBy(dx: -padding, dy: -padding)] : []
                )
            }
        )
    }
}

// MARK: - Key window

open class DonkKeyWindow: UIWindow, DonkWindowMarker {
    public private(set) weak var previousKeyWindow: UIWindow?
    public private(set) var isPresented = false
    public var restoresAppKeyWindowWhenIdle = true

    private var observers: [NSObjectProtocol] = []
    private var isKeyCheckScheduled = false
    private var wantsKeyForTextInput = false
    private var textInputTouchGeneration = 0

    public override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public convenience init(
        windowScene: UIWindowScene,
        level: UIWindow.Level = DonkWindowLevel.debugger,
        rootViewController: UIViewController? = nil
    ) {
        self.init(windowScene: windowScene)
        windowLevel = level
        if let rootViewController {
            self.rootViewController = rootViewController
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    open override var canBecomeKey: Bool {
        !restoresAppKeyWindowWhenIdle || wantsKeyForTextInput || isEditingText
    }

    open override func sendEvent(_ event: UIEvent) {
        if event.type == .touches {
            trackTextInputTouches(event)
        }
        super.sendEvent(event)
    }

    open override func makeKeyAndVisible() {
        rememberPreviousKeyWindow()
        super.makeKeyAndVisible()
    }

    open override func makeKey() {
        rememberPreviousKeyWindow()
        super.makeKey()
    }

    open override func becomeKey() {
        super.becomeKey()
        scheduleKeyCheck()
    }

    open func present() {
        rememberPreviousKeyWindow()
        if let previous = previousKeyWindow, Self.hasTextInputFirstResponder(in: previous) {
            previous.endEditing(true)
        }
        isPresented = true
        startObserving()
        isHidden = false
    }

    open func dismiss() {
        isPresented = false
        stopObserving()
        let wasKey = isKeyWindow
        endEditing(true)
        isHidden = true
        if wasKey || isKeyWindow || windowScene?.keyWindow == nil {
            restoreAppKeyWindow()
        }
        previousKeyWindow = nil
    }

    public var isEditingText: Bool {
        Self.hasTextInputFirstResponder(in: self)
    }

    public func restoreAppKeyWindow() {
        guard let target = keyWindowToRestore, target !== self else { return }
        target.makeKey()
    }

    private var keyWindowToRestore: UIWindow? {
        if let previous = previousKeyWindow, previous.windowScene != nil, !previous.isHidden,
           windowScene == nil || previous.windowScene === windowScene {
            return previous
        }
        return DonkWindowManager.appWindows(in: windowScene)
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.canBecomeKey }
            .last { $0.windowLevel == .normal }
            ?? DonkWindowManager.appWindows(in: windowScene).last { !$0.isHidden && $0.canBecomeKey }
    }

    private func rememberPreviousKeyWindow() {
        guard let scene = windowScene else { return }
        let current = scene.keyWindow ?? scene.windows.first { $0.isKeyWindow }
        guard let current, current !== self, !(current is DonkWindowMarker) else { return }
        previousKeyWindow = current
    }

    // MARK: - Editing-driven key status

    private func trackTextInputTouches(_ event: UIEvent) {
        let touches = event.allTouches?.filter { $0.window === self } ?? []
        guard !touches.isEmpty else { return }
        if touches.contains(where: { $0.phase == .began && Self.isTextInput($0.view) }) {
            textInputTouchGeneration += 1
            wantsKeyForTextInput = true
            return
        }
        guard wantsKeyForTextInput, touches.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) else { return }
        let generation = textInputTouchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.textInputTouchGeneration == generation else { return }
                self.wantsKeyForTextInput = false
                self.scheduleKeyCheck()
            }
        }
    }

    static func isTextInput(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is UITextField || candidate is UISearchBar { return true }
            if let textView = candidate as? UITextView { return textView.isEditable }
            current = candidate.superview
        }
        return false
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let began: @Sendable (Notification) -> Void = { [weak self] notification in
            let object = notification.object as AnyObject?
            MainActor.assumeIsolated { self?.textInputDidBeginEditing(object) }
        }
        let ended: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleKeyCheck() }
        }
        observers = [
            center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main, using: began),
            center.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main, using: began),
            center.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: .main, using: ended),
            center.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: .main, using: ended),
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main, using: ended),
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main, using: ended),
            center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                let object = notification.object as AnyObject?
                MainActor.assumeIsolated { self?.windowDidBecomeKey(object) }
            },
        ]
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func textInputDidBeginEditing(_ object: AnyObject?) {
        guard isPresented, !isHidden, let view = object as? UIView, view.window === self, !isKeyWindow else { return }
        makeKey()
    }

    private func windowDidBecomeKey(_ object: AnyObject?) {
        guard let window = object as? UIWindow, window !== self, !(window is DonkWindowMarker),
              window.windowScene === windowScene else { return }
        previousKeyWindow = window
    }

    private func scheduleKeyCheck() {
        guard !isKeyCheckScheduled else { return }
        isKeyCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performKeyCheck() }
        }
    }

    private func performKeyCheck() {
        isKeyCheckScheduled = false
        guard isKeyWindow else { return }
        if isPresented, !isHidden, !restoresAppKeyWindowWhenIdle || wantsKeyForTextInput || isEditingText { return }
        restoreAppKeyWindow()
    }

    // MARK: - First responder

    static func hasTextInputFirstResponder(in window: UIWindow) -> Bool {
        guard let responder = firstResponder(in: window) else { return false }
        return responder is UIKeyInput
    }

    static func firstResponder(in window: UIWindow) -> UIResponder? {
        if window.isKeyWindow {
            DonkFirstResponderProbe.found = nil
            UIApplication.shared.sendAction(#selector(UIResponder.donk_reportFirstResponder(_:)), to: nil, from: nil, for: nil)
            defer { DonkFirstResponderProbe.found = nil }
            if let responder = DonkFirstResponderProbe.found {
                if let view = responder as? UIView { return view.window === window ? view : nil }
                return responder
            }
            return nil
        }
        return firstResponderView(in: window)
    }

    private static func firstResponderView(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponderView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - First responder probe

@MainActor
enum DonkFirstResponderProbe {
    static weak var found: UIResponder?
}

extension UIResponder {
    @objc func donk_reportFirstResponder(_ sender: Any?) {
        DonkFirstResponderProbe.found = self
    }
}
