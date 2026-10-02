import DonkUI
import SwiftUI

// MARK: - Mode metadata

extension InspectorMode {
    var title: String {
        switch self {
        case .select: return "Select & Measure"
        case .frames: return "Frames"
        case .grid: return "Grid"
        case .colorPicker: return "Eyedropper"
        }
    }

    var shortTitle: String {
        switch self {
        case .select: return "Select"
        case .frames: return "Frames"
        case .grid: return "Grid"
        case .colorPicker: return "Eyedropper"
        }
    }

    var icon: String {
        switch self {
        case .select: return "cursorarrow.rays"
        case .frames: return "square.dashed"
        case .grid: return "squareshape.split.3x3"
        case .colorPicker: return "eyedropper.halffull"
        }
    }

    var summary: String {
        switch self {
        case .select:
            return "Tap any element to see its size, frame, padding to the superview, fonts, colors and hierarchy. Measure the distance between two views."
        case .frames:
            return "Outline every visible view, colored by depth or by kind. The app stays fully usable underneath."
        case .grid:
            return "Overlay a layout grid with adjustable cell width and height, columns, color and offset."
        case .colorPicker:
            return "Touch and drag to magnify pixels and read exact sRGB colors. Lift to copy the HEX."
        }
    }

    var tone: DonkTone {
        switch self {
        case .select: return .accent
        case .frames: return .info
        case .grid: return .warning
        case .colorPicker: return .success
        }
    }
}

// MARK: - Root

struct InspectorOverlayRoot: View {
    @ObservedObject var controller: InspectorController
    @ObservedObject var settings: InspectorSettingsStore
    let sceneID: ObjectIdentifier

    var body: some View {
        ZStack {
            if controller.mode == .grid {
                GridCanvasView(grid: settings.settings.grid)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            if controller.capturesPointer {
                PointerCaptureLayer(controller: controller, sceneID: sceneID)
            }
            if controller.mode != nil {
                OverlayChrome(controller: controller, settings: settings, sceneID: sceneID)
                    .transition(.opacity)
            }
            if let loupe = controller.loupe, loupe.sceneID == sceneID, controller.mode == .colorPicker {
                LoupeOverlay(state: loupe)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(InspectorController.modeAnimation, value: controller.mode)
    }
}

// MARK: - Pointer capture

private struct PointerCaptureLayer: View {
    let controller: InspectorController
    let sceneID: ObjectIdentifier
    @GestureState private var isGestureActive = false
    @State private var isTracking = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($isGestureActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        controller.pointer(isTracking ? .moved : .began, at: value.location, sceneID: sceneID)
                        isTracking = true
                    }
                    .onEnded { value in
                        isTracking = false
                        controller.pointer(.ended, at: value.location, sceneID: sceneID)
                    }
            )
            .onChange(of: isGestureActive) { active in
                guard !active, isTracking else { return }
                isTracking = false
                controller.pointer(.cancelled, at: .zero, sceneID: sceneID)
            }
            .donkInteractive()
            .accessibilityHidden(true)
    }
}

// MARK: - Chrome

private struct OverlayChrome: View {
    @ObservedObject var controller: InspectorController
    @ObservedObject var settings: InspectorSettingsStore
    let sceneID: ObjectIdentifier
    @State private var dragOffset: CGFloat = 0
    @Namespace private var namespace

    private var edge: ToolbarEdge { settings.settings.toolbarEdge }

    private var showsInfoPanel: Bool {
        controller.mode == .select && controller.info != nil && controller.selectionSceneID == sceneID
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                if edge == .top {
                    toolbar(height: proxy.size.height)
                    accessory
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if panelAtTop {
                    sheet(proxy)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if !panelAtTop {
                    sheet(proxy)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if edge == .bottom {
                    accessory
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    toolbar(height: proxy.size.height)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .opacity(controller.mode == .colorPicker && controller.isPointerDown ? 0.3 : 1)
        .animation(InspectorController.modeAnimation, value: controller.info?.nodeID)
        .animation(InspectorController.modeAnimation, value: controller.isMeasuring)
        .animation(InspectorController.modeAnimation, value: controller.isPanelExpanded)
        .animation(InspectorController.modeAnimation, value: controller.panelPrefersTop)
    }

    private var panelAtTop: Bool {
        showsInfoPanel && controller.panelPrefersTop
    }

    private func toolbar(height: CGFloat) -> some View {
        InspectorToolbar(controller: controller, settings: settings)
            .matchedGeometryEffect(id: "toolbar", in: namespace)
            .offset(y: dragOffset)
            .highPriorityGesture(toolbarDrag(height: height))
            .zIndex(2)
    }

    private func toolbarDrag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let target: ToolbarEdge = value.predictedEndLocation.y > height / 2 ? .bottom : .top
                DonkHaptics.light()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                    settings.settings.toolbarEdge = target
                    dragOffset = 0
                }
            }
    }

    @ViewBuilder
    private var accessory: some View {
        switch controller.mode {
        case .select:
            if controller.selection == nil || controller.selectionSceneID != sceneID {
                SelectHintBar(controller: controller, settings: settings)
            } else if controller.isMeasuring && controller.measureTarget == nil {
                MeasureHintBar(controller: controller)
            }
        case .frames:
            FramesLegendBar(settings: settings)
        case .colorPicker:
            EyedropperBar(controller: controller, settings: settings)
        case .grid, .none:
            EmptyView()
        }
    }

    private func detailsHeight(_ proxy: GeometryProxy) -> CGFloat {
        let container = proxy.frame(in: .global)
        let cap = proxy.size.height * 0.5
        guard let rect = controller.panelAnchorRect else { return cap }
        let toolbarSpace: CGFloat = 60
        let headerSpace: CGFloat = 200
        let available: CGFloat
        if panelAtTop {
            available = rect.minY - container.minY - (edge == .top ? toolbarSpace : 0) - 16
        } else {
            available = container.maxY - rect.maxY - (edge == .bottom ? toolbarSpace : 0) - 16
        }
        return min(cap, max(170, available - headerSpace))
    }

    private func sheet(_ proxy: GeometryProxy) -> some View {
        sheet(maxHeight: proxy.size.height, detailsHeight: detailsHeight(proxy), width: max(0, min(560, proxy.size.width - 20)))
    }

    @ViewBuilder
    private func sheet(maxHeight: CGFloat, detailsHeight: CGFloat, width: CGFloat) -> some View {
        if showsInfoPanel, let info = controller.info {
            InfoPanel(controller: controller, settings: settings, info: info, maxHeight: detailsHeight, isAtTop: panelAtTop)
                .frame(width: width)
        } else if controller.mode == .grid {
            GridControlsPanel(settings: settings, maxHeight: maxHeight * 0.42)
                .frame(width: width)
        }
    }
}

// MARK: - Panel surface

struct InspectorPanelBackground: ViewModifier {
    var radius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .donkFloatingShadow()
    }
}

extension View {
    func inspectorPanel(radius: CGFloat = 24) -> some View {
        modifier(InspectorPanelBackground(radius: radius))
    }

    func inspectorGlassBar(radius: CGFloat = 20) -> some View {
        donkGlassBackground(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .donkFloatingShadow()
    }
}
