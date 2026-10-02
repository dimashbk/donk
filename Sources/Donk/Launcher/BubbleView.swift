import DonkInspector
import DonkUI
import SwiftUI

// MARK: - Root

struct BubbleRootView: View {
    @ObservedObject var model: BubbleModel
    let sceneID: ObjectIdentifier

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var isPressed = false
    @State private var pressStart: Date?
    @State private var longPressFired = false
    @State private var longPressWork: DispatchWorkItem?
    @State private var menuSize: CGSize = .zero
    @State private var hasAppeared = false
    @GestureState private var isTouching = false

    private let longPressDuration: TimeInterval = 0.4
    private let dragThreshold: CGFloat = 6

    private var isMenuOpen: Bool {
        model.menuScene == sceneID
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let anchor = BubbleLayout.center(for: model.placement, in: size)
            let center = isDragging
                ? BubbleLayout.clamp(CGPoint(x: anchor.x + dragTranslation.width, y: anchor.y + dragTranslation.height), in: size)
                : anchor
            ZStack(alignment: .topLeading) {
                if isMenuOpen {
                    dismissLayer
                }
                bubble(size: size, anchor: anchor)
                    .donkInteractive(!model.isHiding)
                    .position(center)
                if isMenuOpen {
                    menu
                        .position(BubbleLayout.menuCenter(menuSize: measuredMenuSize, bubbleCenter: center, edge: model.placement.edge, in: size))
                        .transition(
                            .scale(scale: 0.86, anchor: model.placement.edge == .right ? .trailing : .leading)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .environment(\.layoutDirection, .leftToRight)
        .ignoresSafeArea(.keyboard)
    }

    private var measuredMenuSize: CGSize {
        menuSize == .zero ? CGSize(width: QuickMenuView.width, height: 320) : menuSize
    }

    // MARK: - Dismiss layer

    private var dismissLayer: some View {
        Color.black.opacity(0.14)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.closeMenu() }
            .donkInteractive()
            .transition(.opacity)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Close quick actions")
    }

    // MARK: - Menu

    private var menu: some View {
        QuickMenuView(
            inspectorMode: model.inspectorMode,
            isHUDVisible: model.isHUDVisible,
            tools: model.tools
        ) { action in
            model.onAction?(action)
        }
        .background(
            GeometryReader { menuProxy in
                Color.clear.preference(key: BubbleMenuSizeKey.self, value: menuProxy.size)
            }
        )
        .onPreferenceChange(BubbleMenuSizeKey.self) { size in
            menuSize = size
        }
        .opacity(menuSize == .zero ? 0 : 1)
        .donkInteractive()
    }

    // MARK: - Bubble

    private func bubble(size: CGSize, anchor: CGPoint) -> some View {
        BubbleButton(
            unseen: model.unseen,
            isPaused: model.isPaused,
            flash: model.flash,
            isPressed: isPressed && !isDragging
        )
        .scaleEffect(model.isHiding ? 0.2 : (hasAppeared ? 1 : 0.4))
        .opacity(model.isHiding ? 0 : (hasAppeared ? 1 : 0))
        .gesture(dragGesture(size: size, anchor: anchor))
        .onChange(of: isTouching) { touching in
            guard !touching else { return }
            DispatchQueue.main.async(execute: recoverFromCancelledGesture)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                hasAppeared = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the debugger")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onToggle?(sceneID) }
        .accessibilityAction(named: "Quick actions") { model.openMenu(in: sceneID) }
    }

    private var accessibilityLabel: String {
        var parts = ["donk debugger"]
        if model.isPaused { parts.append("requests paused") }
        if model.unseen > 0 { parts.append("\(model.unseen) new requests") }
        return parts.joined(separator: ", ")
    }

    private func dragGesture(size: CGSize, anchor: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isTouching) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if pressStart == nil {
                    beginPress()
                }
                let distance = hypot(value.translation.width, value.translation.height)
                if !isDragging, !longPressFired, distance > dragThreshold {
                    cancelLongPress()
                    isDragging = true
                    model.closeMenu()
                }
                if isDragging {
                    dragTranslation = value.translation
                }
            }
            .onEnded { value in
                defer { resetPress() }
                if isDragging {
                    let start = BubbleLayout.clamp(
                        CGPoint(x: anchor.x + value.translation.width, y: anchor.y + value.translation.height),
                        in: size
                    )
                    let predicted = CGPoint(
                        x: anchor.x + value.predictedEndTranslation.width,
                        y: anchor.y + value.predictedEndTranslation.height
                    )
                    let placement = BubbleLayout.placement(releasedAt: start, predicted: predicted, in: size)
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                        model.commit(placement)
                        isDragging = false
                        dragTranslation = .zero
                    }
                    DonkHaptics.light()
                    return
                }
                if longPressFired { return }
                if isMenuOpen {
                    model.closeMenu()
                } else {
                    DonkHaptics.light()
                    model.onToggle?(sceneID)
                }
            }
    }

    private func beginPress() {
        pressStart = Date()
        longPressFired = false
        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
            isPressed = true
        }
        let work = DispatchWorkItem {
            guard !isDragging, pressStart != nil else { return }
            longPressFired = true
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                isPressed = false
            }
            model.openMenu(in: sceneID)
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)
    }

    private func recoverFromCancelledGesture() {
        guard pressStart != nil else { return }
        resetPress()
        guard isDragging else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
            isDragging = false
            dragTranslation = .zero
        }
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private func resetPress() {
        cancelLongPress()
        pressStart = nil
        longPressFired = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
            isPressed = false
        }
    }
}

private struct BubbleMenuSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

// MARK: - Button

struct BubbleButton: View {
    let unseen: Int
    let isPaused: Bool
    let flash: BubbleFlash?
    let isPressed: Bool

    var body: some View {
        ZStack {
            Image(systemName: isPaused ? "pause.fill" : "ladybug.fill")
                .font(.system(size: isPaused ? 20 : 23, weight: .semibold))
                .foregroundColor(isPaused ? DonkColor.warning : DonkColor.accent)
                .transition(.scale.combined(with: .opacity))
                .id(isPaused)
        }
        .frame(width: BubbleLayout.diameter, height: BubbleLayout.diameter)
        .donkGlassBackground(Circle(), tint: isPaused ? DonkColor.warning.opacity(0.18) : nil)
        .overlay(PausedRing(isActive: isPaused))
        .overlay(flashRing)
        .overlay(alignment: .topTrailing) {
            if unseen > 0 {
                CountBadge(unseen, tone: .error)
                    .offset(x: 6, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: unseen > 0)
        .contentShape(Circle())
        .donkFloatingShadow()
        .scaleEffect(isPressed ? 0.9 : 1)
    }

    @ViewBuilder
    private var flashRing: some View {
        if let flash, !isPaused {
            FlashRing(tone: flash.tone)
                .id(flash.id)
        }
    }
}

private struct FlashRing: View {
    let tone: DonkTone
    @State private var progress: CGFloat = 0

    var body: some View {
        Circle()
            .strokeBorder(tone.color, lineWidth: 3 - progress * 1.5)
            .scaleEffect(1 + progress * 0.32)
            .opacity(Double(1 - progress))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.75)) {
                    progress = 1
                }
            }
    }
}

private struct PausedRing: View {
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .strokeBorder(DonkColor.warning, lineWidth: 2.5)
            .opacity(isActive ? (pulse ? 0.45 : 1) : 0)
            .allowsHitTesting(false)
            .onAppear(perform: updatePulse)
            .onChange(of: isActive) { _ in updatePulse() }
    }

    private func updatePulse() {
        guard isActive, !UIAccessibility.isReduceMotionEnabled else {
            pulse = false
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Quick menu

struct QuickMenuView: View {
    static let width: CGFloat = 248

    let inspectorMode: InspectorMode?
    let isHUDVisible: Bool
    var tools: Set<DonkTool> = Set(DonkTool.allCases)
    let onAction: (BubbleQuickAction) -> Void

    private var showsUtilities: Bool {
        tools.contains(.performance) || tools.contains(.network)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tools.contains(.inspector) {
                Text("Inspector")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundColor(DonkColor.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(InspectorMode.allCases, id: \.self) { mode in
                    row(
                        icon: mode.menuIcon,
                        title: mode.menuTitle,
                        tone: .accent,
                        isOn: inspectorMode == mode,
                        action: .inspector(mode)
                    )
                }
                if inspectorMode != nil {
                    row(icon: "xmark.circle", title: "Stop inspector", tone: .neutral, action: .stopInspector)
                }
                separator
            } else {
                Color.clear.frame(height: 6)
            }
            if showsUtilities {
                if tools.contains(.performance) {
                    row(icon: "speedometer", title: "FPS HUD", tone: .success, toggle: isHUDVisible, action: .toggleHUD)
                }
                if tools.contains(.network) {
                    row(icon: "trash", title: "Clear network log", tone: .error, action: .clearNetworkLog)
                }
                separator
            }
            row(icon: "eye.slash", title: "Hide bubble", tone: .neutral, action: .hideBubble)
                .padding(.bottom, 6)
        }
        .frame(width: Self.width)
        .donkGlassBackground(RoundedRectangle(cornerRadius: DonkRadius.large, style: .continuous))
        .donkFloatingShadow()
    }

    private var separator: some View {
        Rectangle()
            .fill(DonkColor.separator.opacity(0.6))
            .frame(height: 0.5)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
    }

    private func row(
        icon: String,
        title: String,
        tone: DonkTone,
        isOn: Bool = false,
        toggle: Bool? = nil,
        action: BubbleQuickAction
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tone.color)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if let toggle {
                    QuickMenuSwitch(isOn: toggle)
                } else if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundColor(DonkColor.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickMenuRowStyle())
        .accessibilityAddTraits(isOn || toggle == true ? .isSelected : [])
    }
}

private struct QuickMenuSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? DonkColor.success : DonkColor.fill)
            .frame(width: 34, height: 20)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .padding(2)
                    .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
            )
            .accessibilityHidden(true)
    }
}

private struct QuickMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(DonkColor.textPrimary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

// MARK: - Inspector labels

extension InspectorMode {
    var menuTitle: String {
        switch self {
        case .select: return "Select element"
        case .frames: return "Show frames"
        case .grid: return "Grid"
        case .colorPicker: return "Color picker"
        }
    }

    var shortTitle: String {
        switch self {
        case .select: return "Select"
        case .frames: return "Frames"
        case .grid: return "Grid"
        case .colorPicker: return "Color picker"
        }
    }

    var menuIcon: String {
        switch self {
        case .select: return "cursorarrow.rays"
        case .frames: return "square.dashed"
        case .grid: return "square.grid.3x3"
        case .colorPicker: return "eyedropper"
        }
    }
}
