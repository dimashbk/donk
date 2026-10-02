import Combine
import DonkCore
import DonkUI
import SwiftUI
import UIKit

@MainActor
final class InspectorController: ObservableObject {
    static let shared = InspectorController()
    static let modeAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86)

    typealias OverlayWindow = DonkHostingPassthroughWindow<InspectorOverlayRoot>

    enum PointerPhase {
        case began, moved, ended, cancelled
    }

    @Published private(set) var mode: InspectorMode?
    @Published private(set) var selection: InspectorNode?
    @Published private(set) var selectionSceneID: ObjectIdentifier?
    @Published private(set) var stack: [InspectorNode] = []
    @Published private(set) var stackIndex = 0
    @Published private(set) var info: InspectorInfo?
    @Published var isPanelExpanded = false
    @Published private(set) var panelPrefersTop = false
    @Published private(set) var panelAnchorRect: CGRect?
    @Published private(set) var isMeasuring = false
    @Published private(set) var measureTarget: InspectorNode?
    @Published private(set) var measurement: MeasureSummary?
    @Published private(set) var loupe: LoupeState?
    @Published private(set) var lastPickedColor: RGBAColor?
    @Published private(set) var snapshotDate: Date?
    @Published private(set) var isPointerDown = false

    let settings = InspectorSettingsStore.shared

    private var windowSet: DonkSceneWindowSet<OverlayWindow>?
    private var canvases: [ObjectIdentifier: InspectorCanvasView] = [:]
    private var snapshots: [ObjectIdentifier: ScreenSnapshot] = [:]
    private let ticker = InspectorTicker()
    private var teardown: DispatchWorkItem?
    private var loupeHide: DispatchWorkItem?
    private var settingsObserver: AnyCancellable?
    private var lastSettings: InspectorSettings

    init() {
        AccessibilityActivation.recoverIfNeeded()
        lastSettings = settings.settings
        settingsObserver = settings.$settings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.settingsChanged(value)
            }
    }

    var capturesPointer: Bool {
        mode == .select || mode == .colorPicker
    }

    var includesSwiftUIElements: Bool {
        settings.settings.includesSwiftUIElements && AccessibilityActivation.isAvailable
    }

    var showsOutlines: Bool {
        mode == .frames || (mode == .select && settings.settings.outlinesWhileSelecting)
    }

    // MARK: - Lifecycle

    func start(_ newMode: InspectorMode) {
        DonkInspector.onWillStart?()
        activate(newMode)
    }

    func activate(_ newMode: InspectorMode) {
        teardown?.cancel()
        teardown = nil
        let previous = mode
        ensureWindows()
        guard previous != newMode else {
            renderAll(animated: false)
            return
        }
        if previous == .select { clearSelection() }
        if newMode != .colorPicker {
            snapshots.removeAll()
            loupe = nil
            snapshotDate = nil
        }
        withAnimation(Self.modeAnimation) {
            mode = newMode
        }
        updateAccessibilityActivation()
        if newMode == .colorPicker {
            DispatchQueue.main.async { [weak self] in
                self?.refreshSnapshots()
            }
        }
        updateTicker()
        renderAll(animated: true)
    }

    func stop() {
        guard mode != nil else { return }
        clearSelection()
        loupeHide?.cancel()
        loupe = nil
        snapshots.removeAll()
        snapshotDate = nil
        isPointerDown = false
        ticker.stop()
        withAnimation(Self.modeAnimation) {
            mode = nil
        }
        updateAccessibilityActivation()
        renderAll(animated: true)
        let work = DispatchWorkItem { [weak self] in
            self?.tearDownWindows()
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func updateAccessibilityActivation() {
        if mode == .select && includesSwiftUIElements {
            AccessibilityActivation.activate()
        } else {
            AccessibilityActivation.restore()
        }
    }

    func openDebugger() {
        DonkInspector.onOpenDebugger?()
    }

    private func ensureWindows() {
        if windowSet == nil {
            windowSet = DonkSceneWindowSet<OverlayWindow> { [unowned self] scene in
                self.makeWindow(for: scene)
            }
        }
        windowSet?.isActive = true
    }

    private func tearDownWindows() {
        teardown = nil
        guard mode == nil else { return }
        windowSet?.isActive = false
        canvases.removeAll()
    }

    private func makeWindow(for scene: UIWindowScene) -> OverlayWindow {
        let sceneID = ObjectIdentifier(scene)
        let window = OverlayWindow(
            windowScene: scene,
            level: DonkWindowLevel.inspector,
            rootView: InspectorOverlayRoot(controller: self, settings: settings, sceneID: sceneID)
        )
        window.accessibilityViewIsModal = false
        let canvas = InspectorCanvasView(frame: window.bounds)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let root = window.rootViewController?.view {
            canvas.frame = root.bounds
            if let hosting = window.hostingView, hosting.superview === root {
                root.insertSubview(canvas, belowSubview: hosting)
            } else {
                root.insertSubview(canvas, at: 0)
            }
        }
        canvases[sceneID] = canvas
        return window
    }

    private func overlayWindow(for sceneID: ObjectIdentifier?) -> OverlayWindow? {
        guard let windows = windowSet?.windows else { return nil }
        if let sceneID {
            return windows.first { $0.windowScene.map(ObjectIdentifier.init) == sceneID }
        }
        return windowSet?.activeWindow ?? windows.first
    }

    // MARK: - Mode switching

    func switchMode(_ newMode: InspectorMode) {
        guard newMode != mode else { return }
        DonkHaptics.selection()
        activate(newMode)
    }

    func toggleOutlinesWhileSelecting() {
        settings.settings.outlinesWhileSelecting.toggle()
    }

    // MARK: - Pointer

    func pointer(_ phase: PointerPhase, at point: CGPoint, sceneID: ObjectIdentifier) {
        guard let window = overlayWindow(for: sceneID) else { return }
        switch mode {
        case .select:
            handleSelectPointer(phase, at: point, window: window, sceneID: sceneID)
        case .colorPicker:
            handleColorPointer(phase, at: point, window: window, sceneID: sceneID)
        default:
            break
        }
    }

    private func handleSelectPointer(_ phase: PointerPhase, at point: CGPoint, window: UIWindow, sceneID: ObjectIdentifier) {
        if phase == .cancelled {
            isPointerDown = false
            return
        }
        let down = phase != .ended
        if isPointerDown != down { isPointerDown = down }
        let hits = ViewHierarchy.hitStack(
            at: point,
            overlay: window,
            includesElements: includesSwiftUIElements,
            reusesElementCache: phase != .began
        )
        guard let top = hits.first else { return }
        if isMeasuring, let selection {
            guard top != selection else { return }
            if top != measureTarget {
                measureTarget = top
                DonkHaptics.selection()
                refreshMeasurement()
                renderAll(animated: false)
            }
            return
        }
        let changed = top != selection
        guard changed || phase == .ended else { return }
        if changed { DonkHaptics.selection() }
        let appearing = selection == nil
        stack = hits
        stackIndex = 0
        selection = top
        selectionSceneID = sceneID
        if appearing, settings.settings.opensPanelExpanded {
            isPanelExpanded = true
        }
        if phase == .ended || appearing {
            updatePanelPlacement()
        }
        refreshInfo(force: true)
        updateTicker()
        renderAll(animated: phase == .began || phase == .ended)
    }

    private func updatePanelPlacement() {
        guard let selection, let overlay = overlayWindow(for: selectionSceneID), let rect = selection.frame(in: overlay) else { return }
        let height = overlay.bounds.height
        let prefersTop = rect.midY > height * 0.52 && rect.height < height * 0.7
        if prefersTop != panelPrefersTop {
            panelPrefersTop = prefersTop
        }
        if panelAnchorRect != rect {
            panelAnchorRect = rect
        }
    }

    // MARK: - Selection

    func select(view: UIView, expandsPanel: Bool) {
        guard let window = view.window, let scene = window.windowScene else { return }
        if mode != .select {
            start(.select)
        }
        let sceneID = ObjectIdentifier(scene)
        let node = InspectorNode(view: view)
        var hits: [InspectorNode] = [node]
        if let overlay = overlayWindow(for: sceneID), let rect = node.frame(in: overlay) {
            let found = ViewHierarchy.hitStack(at: CGPoint(x: rect.midX, y: rect.midY), overlay: overlay, includesElements: false, reusesElementCache: false)
            if found.contains(node) { hits = found }
        }
        stack = hits
        stackIndex = hits.firstIndex(of: node) ?? 0
        selection = node
        selectionSceneID = sceneID
        measureTarget = nil
        measurement = nil
        if expandsPanel { isPanelExpanded = true }
        updatePanelPlacement()
        refreshInfo(force: true)
        updateTicker()
        renderAll(animated: true)
    }

    func select(at point: CGPoint, expandsPanel: Bool) {
        if mode != .select {
            start(.select)
        }
        guard let window = overlayWindow(for: nil), let scene = window.windowScene else { return }
        let sceneID = ObjectIdentifier(scene)
        let hits = ViewHierarchy.hitStack(
            at: point,
            overlay: window,
            includesElements: includesSwiftUIElements,
            reusesElementCache: false
        )
        guard let top = hits.first else { return }
        stack = hits
        stackIndex = 0
        selection = top
        selectionSceneID = sceneID
        measureTarget = nil
        measurement = nil
        if expandsPanel { isPanelExpanded = true }
        updatePanelPlacement()
        refreshInfo(force: true)
        updateTicker()
        renderAll(animated: true)
    }

    func select(_ node: InspectorNode) {
        guard node.isAlive else { return }
        DonkHaptics.selection()
        if let index = stack.firstIndex(of: node) {
            stackIndex = index
        } else if let sceneID = node.sceneID ?? selectionSceneID, let overlay = overlayWindow(for: sceneID), let rect = node.frame(in: overlay) {
            let found = ViewHierarchy.hitStack(
                at: CGPoint(x: rect.midX, y: rect.midY),
                overlay: overlay,
                includesElements: includesSwiftUIElements,
                reusesElementCache: false
            )
            if let index = found.firstIndex(of: node) {
                stack = found
                stackIndex = index
            } else {
                stack = [node]
                stackIndex = 0
            }
        } else {
            stack = [node]
            stackIndex = 0
        }
        selection = node
        selectionSceneID = node.sceneID ?? selectionSceneID
        if measureTarget == node {
            measureTarget = nil
        }
        updatePanelPlacement()
        refreshInfo(force: true)
        updateTicker()
        renderAll(animated: true)
    }

    func selectParent() {
        guard let parent = selection?.parent else { return }
        select(parent)
    }

    func selectNextUnderneath() {
        guard stack.count > 1 else { return }
        DonkHaptics.selection()
        var index = stackIndex
        for _ in 0..<stack.count {
            index = (index + 1) % stack.count
            if stack[index].isAlive, stack[index] != measureTarget { break }
        }
        stackIndex = index
        selection = stack[index]
        updatePanelPlacement()
        refreshInfo(force: true)
        renderAll(animated: true)
    }

    func clearSelection() {
        selection = nil
        selectionSceneID = nil
        stack = []
        stackIndex = 0
        info = nil
        measureTarget = nil
        measurement = nil
        isMeasuring = false
        isPanelExpanded = settings.settings.opensPanelExpanded
        updateTicker()
        renderAll(animated: true)
    }

    func toggleMeasuring() {
        withAnimation(Self.modeAnimation) {
            isMeasuring.toggle()
        }
        if !isMeasuring {
            measureTarget = nil
            measurement = nil
        }
        DonkHaptics.selection()
        renderAll(animated: true)
    }

    func measure(to view: UIView) {
        guard let selection, selection.view !== view else { return }
        isMeasuring = true
        measureTarget = InspectorNode(view: view)
        refreshMeasurement()
        renderAll(animated: true)
    }

    func clearMeasureTarget() {
        measureTarget = nil
        measurement = nil
        renderAll(animated: true)
    }

    // MARK: - Info

    func formatter(for window: UIWindow?) -> UnitFormatter {
        UnitFormatter(unit: settings.settings.unit, scale: window?.screen.scale ?? UIScreen.main.scale)
    }

    private func refreshInfo(force: Bool = false) {
        guard let selection else {
            if info != nil { info = nil }
            return
        }
        guard selection.isAlive else {
            clearSelection()
            return
        }
        let overlay = overlayWindow(for: selectionSceneID)
        let context = InfoBuilder.Context(
            formatter: formatter(for: overlay),
            includesModule: settings.settings.showsModulePrefix,
            overlay: overlay,
            stackPosition: stackIndex,
            stackCount: stack.count
        )
        let built = InfoBuilder.build(for: selection, context: context)
        if force || built != info {
            info = built
        }
        refreshMeasurement()
    }

    private func refreshMeasurement() {
        guard let selection, let target = measureTarget, let overlay = overlayWindow(for: selectionSceneID),
              let selectionRect = selection.frame(in: overlay), let targetRect = target.frame(in: overlay) else {
            if measurement != nil { measurement = nil }
            return
        }
        let format = formatter(for: overlay)
        let result = Measurement.between(selectionRect, targetRect)
        var rows = result.values.map { InfoRow($0.title, format.length($0.value), monospaced: true) }
        rows.append(InfoRow("Target size", format.sizeWithUnit(target.contentSize), monospaced: true))
        let title: String
        if let view = target.view {
            title = InfoBuilder.shortName(of: view)
        } else {
            title = target.summary?.label.map { "“\($0)”" } ?? "SwiftUI element"
        }
        let summary = MeasureSummary(targetTitle: title, relation: result.relation, rows: rows)
        if summary != measurement {
            measurement = summary
        }
    }

    // MARK: - Rendering

    private func updateTicker() {
        let needsTicks = showsOutlines || (mode == .select && selection != nil)
        if needsTicks {
            guard !ticker.isRunning else { return }
            ticker.start { [weak self] in
                self?.tick()
            }
        } else {
            ticker.stop()
        }
    }

    private func tick() {
        if selection != nil {
            refreshInfo()
        }
        renderAll(animated: false)
    }

    private func renderAll(animated: Bool) {
        guard let windows = windowSet?.windows else { return }
        var live = Set<ObjectIdentifier>()
        for window in windows {
            guard let scene = window.windowScene else { continue }
            let sceneID = ObjectIdentifier(scene)
            live.insert(sceneID)
            canvases[sceneID]?.apply(makeScene(for: window, sceneID: sceneID), animated: animated)
        }
        if canvases.count > live.count {
            canvases = canvases.filter { live.contains($0.key) }
        }
    }

    private func makeScene(for window: UIWindow, sceneID: ObjectIdentifier) -> CanvasScene {
        var scene = CanvasScene()
        guard let mode else { return scene }
        let format = formatter(for: window)
        if showsOutlines {
            scene.outlines = ViewHierarchy.outlines(
                in: window,
                palette: settings.settings.framesPalette,
                includesSizes: settings.settings.showsFrameSizes,
                formatter: format
            )
        }
        guard mode == .select, let selection, selectionSceneID == sceneID, let rect = selection.frame(in: window) else {
            return scene
        }
        scene.selectionID = selection.id
        scene.selection = rect
        scene.selectionLabel = format.size(selection.contentSize)
        if let target = measureTarget, let targetRect = target.frame(in: window) {
            scene.target = targetRect
            let result = Measurement.between(rect, targetRect)
            scene.lines = result.lines.map { CanvasLine(start: $0.start, end: $0.end, text: format.label(abs($0.value))) }
            scene.guides = result.guides
        } else if let parent = selection.parentFrame(in: window) {
            scene.parent = parent
            scene.lines = Measurement.insets(of: rect, in: parent).map {
                CanvasLine(start: $0.start, end: $0.end, text: format.label($0.value))
            }
        }
        return scene
    }

    private func settingsChanged(_ value: InspectorSettings) {
        let previous = lastSettings
        lastSettings = value
        let affectsCanvas = previous.framesPalette != value.framesPalette
            || previous.showsFrameSizes != value.showsFrameSizes
            || previous.outlinesWhileSelecting != value.outlinesWhileSelecting
            || previous.unit != value.unit
        let affectsInfo = previous.unit != value.unit
            || previous.showsModulePrefix != value.showsModulePrefix
            || previous.includesSwiftUIElements != value.includesSwiftUIElements
        guard mode != nil else { return }
        if previous.includesSwiftUIElements != value.includesSwiftUIElements {
            updateAccessibilityActivation()
        }
        if affectsInfo { refreshInfo(force: true) }
        if affectsCanvas {
            updateTicker()
            renderAll(animated: true)
        }
    }

    // MARK: - Eyedropper

    func refreshSnapshots() {
        guard mode == .colorPicker, let windows = windowSet?.windows else { return }
        snapshots.removeAll()
        for window in windows {
            guard let scene = window.windowScene else { continue }
            if let snapshot = ScreenSnapshot.capture(for: window) {
                snapshots[ObjectIdentifier(scene)] = snapshot
            }
        }
        snapshotDate = Date()
        if let current = loupe, let snapshot = snapshots[current.sceneID] {
            loupe = snapshot.loupe(at: current.point, sceneID: current.sceneID, isPinned: current.isPinned)
        }
    }

    func refreshSnapshotsFromUI() {
        DonkHaptics.light()
        refreshSnapshots()
        DonkToast.show("Snapshot refreshed", icon: "camera.viewfinder", tone: .neutral, duration: 1.2)
    }

    private func snapshot(for window: UIWindow, sceneID: ObjectIdentifier) -> ScreenSnapshot? {
        if let existing = snapshots[sceneID] { return existing }
        guard let captured = ScreenSnapshot.capture(for: window) else { return nil }
        snapshots[sceneID] = captured
        snapshotDate = Date()
        return captured
    }

    private func handleColorPointer(_ phase: PointerPhase, at point: CGPoint, window: UIWindow, sceneID: ObjectIdentifier) {
        loupeHide?.cancel()
        switch phase {
        case .began, .moved:
            if !isPointerDown {
                withAnimation(.easeOut(duration: 0.15)) { isPointerDown = true }
            }
            guard let snapshot = snapshot(for: window, sceneID: sceneID) else { return }
            let next = snapshot.loupe(at: point, sceneID: sceneID, isPinned: false)
            if phase == .began || next.pixelX != loupe?.pixelX || next.pixelY != loupe?.pixelY || loupe?.isPinned == true {
                loupe = next
            }
        case .ended:
            withAnimation(.easeOut(duration: 0.2)) { isPointerDown = false }
            if let color = loupe?.center {
                commit(color)
            }
            scheduleLoupeHide(after: 0.9)
        case .cancelled:
            withAnimation(.easeOut(duration: 0.2)) { isPointerDown = false }
            scheduleLoupeHide(after: 0)
        }
    }

    private func scheduleLoupeHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.loupe?.isPinned != true else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.loupe = nil
            }
        }
        loupeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commit(_ color: RGBAColor) {
        lastPickedColor = color
        DonkPasteboard.copy(color.hex, label: color.hex)
        settings.addRecentColor(color.hex)
    }

    func copyColor(_ hex: String) {
        guard let color = RGBAColor(hex: hex) else { return }
        lastPickedColor = color
        DonkPasteboard.copy(color.hex, label: color.hex)
    }

    func sampleColor(at point: CGPoint) -> String? {
        if mode != .colorPicker {
            start(.colorPicker)
        }
        guard let window = overlayWindow(for: nil), let scene = window.windowScene else { return nil }
        let sceneID = ObjectIdentifier(scene)
        snapshots[sceneID] = nil
        guard let snapshot = snapshot(for: window, sceneID: sceneID) else { return nil }
        loupeHide?.cancel()
        let state = snapshot.loupe(at: point, sceneID: sceneID, isPinned: true)
        loupe = state
        if let color = state.center {
            lastPickedColor = color
            settings.addRecentColor(color.hex)
        }
        return state.center?.hex
    }
}
