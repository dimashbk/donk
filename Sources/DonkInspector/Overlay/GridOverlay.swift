import DonkUI
import SwiftUI

// MARK: - Canvas

struct GridCanvasView: View {
    let grid: GridSettings

    var body: some View {
        Canvas { context, size in
            let color = grid.color.color
            if grid.columns.isEnabled {
                drawColumns(in: &context, size: size, color: color)
            }
            guard grid.showsLines else { return }
            var path = Path()
            if grid.showsVerticalLines {
                let step = CGFloat(grid.cellWidth)
                var x = CGFloat(grid.offsetX).truncatingRemainder(dividingBy: step)
                if x < 0 { x += step }
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
            }
            if grid.showsHorizontalLines {
                let step = CGFloat(grid.cellHeight)
                var y = CGFloat(grid.offsetY).truncatingRemainder(dividingBy: step)
                if y < 0 { y += step }
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
            }
            context.stroke(path, with: .color(color.opacity(grid.opacity)), lineWidth: CGFloat(grid.lineWidth))
        }
        .accessibilityHidden(true)
    }

    private func drawColumns(in context: inout GraphicsContext, size: CGSize, color: Color) {
        let columns = grid.columns
        let count = CGFloat(columns.count)
        let margin = CGFloat(columns.margin)
        let gutter = CGFloat(columns.gutter)
        let width = (size.width - margin * 2 - gutter * (count - 1)) / count
        guard width > 0 else { return }
        var fill = Path()
        var edges = Path()
        for index in 0..<columns.count {
            let x = margin + CGFloat(index) * (width + gutter) + CGFloat(grid.offsetX)
            let rect = CGRect(x: x, y: 0, width: width, height: size.height)
            fill.addRect(rect)
            edges.move(to: CGPoint(x: rect.minX, y: 0))
            edges.addLine(to: CGPoint(x: rect.minX, y: size.height))
            edges.move(to: CGPoint(x: rect.maxX, y: 0))
            edges.addLine(to: CGPoint(x: rect.maxX, y: size.height))
        }
        if columns.isFilled {
            context.fill(fill, with: .color(color.opacity(min(grid.opacity, 0.5) * 0.45)))
        }
        context.stroke(edges, with: .color(color.opacity(grid.opacity)), lineWidth: CGFloat(grid.lineWidth))
    }
}

// MARK: - Controls panel

struct GridControlsPanel: View {
    @ObservedObject var settings: InspectorSettingsStore
    let maxHeight: CGFloat
    @State private var isCollapsed = false
    @State private var editing: GridField?

    private var grid: GridSettings { settings.settings.grid }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                if let editing {
                    NumericKeypad(
                        title: editing.title,
                        unit: editing.unit,
                        range: editing.range,
                        allowsDecimal: editing.allowsDecimal,
                        initialValue: value(for: editing),
                        onCommit: { newValue in
                            setValue(newValue, for: editing)
                            withAnimation(InspectorController.modeAnimation) { self.editing = nil }
                        },
                        onCancel: {
                            withAnimation(InspectorController.modeAnimation) { self.editing = nil }
                        }
                    )
                    .padding(14)
                    .transition(.opacity)
                } else {
                    ScrollView {
                        controls
                            .padding(14)
                    }
                    .frame(maxHeight: maxHeight)
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: 560)
        .inspectorPanel()
        .donkInteractive()
    }

    private var header: some View {
        HStack(spacing: 10) {
            DonkIconBadge("squareshape.split.3x3", tone: .warning, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Grid")
                    .font(DonkFont.headline)
                Text(summary)
                    .font(DonkFont.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                DonkHaptics.light()
                settings.resetGrid()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.donkPressable)
            .accessibilityLabel("Reset grid")
            Button {
                DonkHaptics.selection()
                withAnimation(InspectorController.modeAnimation) {
                    isCollapsed.toggle()
                    editing = nil
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(DonkColor.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.donkPressable)
            .accessibilityLabel(isCollapsed ? "Show grid controls" : "Hide grid controls")
        }
        .foregroundColor(DonkColor.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        var parts: [String] = []
        if grid.showsLines {
            let width = UnitFormatter.number(CGFloat(grid.cellWidth))
            let height = UnitFormatter.number(CGFloat(grid.cellHeight))
            if grid.showsVerticalLines && grid.showsHorizontalLines {
                parts.append("\(width) × \(height) pt")
            } else if grid.showsHorizontalLines {
                parts.append("\(height) pt rows")
            } else {
                parts.append("\(width) pt columns")
            }
        }
        if grid.columns.isEnabled {
            parts.append("\(grid.columns.count) columns")
        }
        parts.append("\(Int((grid.opacity * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GridPreset.all) { preset in
                        FilterChip(title: preset.title, icon: preset.icon, isSelected: preset.matches(grid)) {
                            settings.apply(preset)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            group("Cell") {
                StepperRow(title: "Width", value: format(grid.cellWidth), unit: "pt", onDecrement: {
                    settings.setCellWidth(grid.cellWidth - 1)
                }, onIncrement: {
                    settings.setCellWidth(grid.cellWidth + 1)
                }, onEdit: { edit(.cellWidth) })
                StepperRow(title: "Height", value: format(grid.cellHeight), unit: "pt", onDecrement: {
                    settings.setCellHeight(grid.cellHeight - 1)
                }, onIncrement: {
                    settings.setCellHeight(grid.cellHeight + 1)
                }, onEdit: { edit(.cellHeight) })
                HStack(spacing: 6) {
                    OverlayChip(title: "Square", icon: "link", isOn: grid.isLinked) {
                        settings.updateGrid { grid in
                            grid.isLinked.toggle()
                            if grid.isLinked { grid.cellHeight = grid.cellWidth }
                        }
                    }
                    OverlayChip(title: "Vertical", icon: "arrow.left.and.right", isOn: grid.showsVerticalLines) {
                        settings.updateGrid { $0.showsVerticalLines.toggle() }
                    }
                    OverlayChip(title: "Horizontal", icon: "arrow.up.and.down", isOn: grid.showsHorizontalLines) {
                        settings.updateGrid { $0.showsHorizontalLines.toggle() }
                    }
                }
            }

            group("Appearance") {
                HStack(spacing: 8) {
                    ForEach(GridSettings.palette, id: \.self) { hex in
                        let isSelected = hex.caseInsensitiveCompare(grid.colorHex) == .orderedSame
                        Button {
                            DonkHaptics.selection()
                            settings.updateGrid { $0.colorHex = hex }
                        } label: {
                            Circle()
                                .fill(RGBAColor(hex: hex)?.color ?? .clear)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0))
                                .overlay(Circle().strokeBorder(DonkColor.textPrimary.opacity(isSelected ? 0.6 : 0), lineWidth: 1).padding(-2))
                                .frame(width: 30, height: 30)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.donkPressable)
                        .accessibilityLabel("Color \(hex)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                SliderRow(title: "Opacity", value: settings.binding(\.grid.opacity), range: 0.05...1, step: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                SliderRow(title: "Line width", value: settings.binding(\.grid.lineWidth), range: 0.25...4, step: 0.25) {
                    "\(UnitFormatter.number(CGFloat($0))) pt"
                }
            }

            group("Origin offset") {
                StepperRow(title: "X", value: format(grid.offsetX), unit: "pt", onDecrement: {
                    settings.updateGrid { $0.offsetX -= 1 }
                }, onIncrement: {
                    settings.updateGrid { $0.offsetX += 1 }
                }, onEdit: { edit(.offsetX) })
                StepperRow(title: "Y", value: format(grid.offsetY), unit: "pt", onDecrement: {
                    settings.updateGrid { $0.offsetY -= 1 }
                }, onIncrement: {
                    settings.updateGrid { $0.offsetY += 1 }
                }, onEdit: { edit(.offsetY) })
            }

            group("Columns") {
                Toggle(isOn: Binding(
                    get: { grid.columns.isEnabled },
                    set: { value in settings.updateGrid { $0.columns.isEnabled = value } }
                )) {
                    Text("Column layout")
                        .font(.subheadline)
                }
                .tint(DonkColor.accent)
                if grid.columns.isEnabled {
                    StepperRow(title: "Count", value: "\(grid.columns.count)", unit: nil, onDecrement: {
                        settings.updateGrid { $0.columns.count -= 1 }
                    }, onIncrement: {
                        settings.updateGrid { $0.columns.count += 1 }
                    }, onEdit: { edit(.columnCount) })
                    StepperRow(title: "Margin", value: format(grid.columns.margin), unit: "pt", onDecrement: {
                        settings.updateGrid { $0.columns.margin -= 1 }
                    }, onIncrement: {
                        settings.updateGrid { $0.columns.margin += 1 }
                    }, onEdit: { edit(.margin) })
                    StepperRow(title: "Gutter", value: format(grid.columns.gutter), unit: "pt", onDecrement: {
                        settings.updateGrid { $0.columns.gutter -= 1 }
                    }, onIncrement: {
                        settings.updateGrid { $0.columns.gutter += 1 }
                    }, onEdit: { edit(.gutter) })
                    OverlayChip(title: "Filled columns", icon: "rectangle.split.3x1", isOn: grid.columns.isFilled) {
                        settings.updateGrid { $0.columns.isFilled.toggle() }
                    }
                }
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(DonkColor.textSecondary)
            content()
        }
    }

    private func format(_ value: Double) -> String {
        UnitFormatter.number(CGFloat(value))
    }

    private func edit(_ field: GridField) {
        DonkHaptics.light()
        withAnimation(InspectorController.modeAnimation) {
            editing = field
        }
    }

    private func value(for field: GridField) -> Double {
        switch field {
        case .cellWidth: return grid.cellWidth
        case .cellHeight: return grid.cellHeight
        case .offsetX: return grid.offsetX
        case .offsetY: return grid.offsetY
        case .columnCount: return Double(grid.columns.count)
        case .margin: return grid.columns.margin
        case .gutter: return grid.columns.gutter
        }
    }

    private func setValue(_ value: Double, for field: GridField) {
        switch field {
        case .cellWidth: settings.setCellWidth(value)
        case .cellHeight: settings.setCellHeight(value)
        case .offsetX: settings.updateGrid { $0.offsetX = value }
        case .offsetY: settings.updateGrid { $0.offsetY = value }
        case .columnCount: settings.updateGrid { $0.columns.count = Int(value.rounded()) }
        case .margin: settings.updateGrid { $0.columns.margin = value }
        case .gutter: settings.updateGrid { $0.columns.gutter = value }
        }
    }
}

// MARK: - Fields

enum GridField: String, Identifiable {
    case cellWidth, cellHeight, offsetX, offsetY, columnCount, margin, gutter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cellWidth: return "Cell width"
        case .cellHeight: return "Cell height"
        case .offsetX: return "Offset X"
        case .offsetY: return "Offset Y"
        case .columnCount: return "Columns"
        case .margin: return "Margin"
        case .gutter: return "Gutter"
        }
    }

    var unit: String {
        self == .columnCount ? "" : "pt"
    }

    var range: ClosedRange<Double> {
        switch self {
        case .cellWidth, .cellHeight: return GridSettings.cellRange
        case .offsetX, .offsetY: return GridSettings.offsetRange
        case .columnCount: return 1...24
        case .margin, .gutter: return 0...200
        }
    }

    var allowsDecimal: Bool {
        self != .columnCount
    }
}

// MARK: - Rows

struct StepperRow: View {
    let title: String
    let value: String
    let unit: String?
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(DonkColor.textPrimary)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                RepeatingButton(symbol: "minus", label: "Decrease \(title)", action: onDecrement)
                Divider().frame(height: 20)
                Button(action: onEdit) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(value)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        if let unit, !unit.isEmpty {
                            Text(unit)
                                .font(.caption2)
                                .foregroundColor(DonkColor.textSecondary)
                        }
                    }
                    .frame(minWidth: 64, minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(DonkColor.accent)
                .accessibilityLabel("\(title), \(value) \(unit ?? "")")
                .accessibilityHint("Opens a keypad")
                Divider().frame(height: 20)
                RepeatingButton(symbol: "plus", label: "Increase \(title)", action: onIncrement)
            }
            .background(Capsule().fill(DonkColor.fill))
        }
    }
}

struct RepeatingButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var timer: Timer?
    @State private var isPressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.bold))
            .foregroundColor(DonkColor.textPrimary)
            .frame(width: 40, height: 34)
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.88 : 1)
            .opacity(isPressed ? 0.6 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        fire()
                        scheduleRepeat()
                    }
                    .onEnded { _ in
                        isPressed = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func fire() {
        DonkHaptics.selection()
        action()
    }

    private func scheduleRepeat() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            DispatchQueue.main.async {
                guard isPressed else { return }
                timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    DispatchQueue.main.async {
                        guard isPressed else { return }
                        action()
                    }
                }
            }
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .frame(width: 80, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .tint(DonkColor.accent)
            Text(format(value))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}
