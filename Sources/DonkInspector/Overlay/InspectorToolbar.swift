import DonkUI
import SwiftUI

// MARK: - Toolbar

struct InspectorToolbar: View {
    @ObservedObject var controller: InspectorController
    @ObservedObject var settings: InspectorSettingsStore
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorMode.allCases, id: \.self) { mode in
                modeButton(mode)
            }
            Capsule()
                .fill(DonkColor.separator)
                .frame(width: 1, height: 22)
                .padding(.horizontal, 5)
            if DonkInspector.onOpenDebugger != nil {
                iconButton("ladybug.fill", label: "Open donk", tint: DonkColor.accent) {
                    controller.openDebugger()
                }
            }
            iconButton("xmark", label: "Close inspector", tint: DonkColor.textPrimary) {
                DonkHaptics.light()
                DonkInspector.stop()
            }
        }
        .padding(4)
        .donkGlassBackground(Capsule(), interactive: true)
        .donkFloatingShadow()
        .donkInteractive(padding: 4)
    }

    private func modeButton(_ mode: InspectorMode) -> some View {
        let isSelected = controller.mode == mode
        let isCombined = mode == .frames && controller.mode == .select && settings.settings.outlinesWhileSelecting
        return Button {
            withAnimation(InspectorController.modeAnimation) {
                controller.switchMode(mode)
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(DonkColor.accent)
                        .matchedGeometryEffect(id: "selected-mode", in: namespace)
                } else if isCombined {
                    Circle()
                        .strokeBorder(DonkColor.accent, lineWidth: 1.5)
                        .background(Circle().fill(DonkColor.accent.opacity(0.12)))
                }
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isSelected ? .white : (isCombined ? DonkColor.accent : DonkColor.textPrimary))
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.donkPressable)
        .accessibilityLabel(mode.shortTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 38, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.donkPressable)
        .accessibilityLabel(label)
    }
}

// MARK: - Shared bits

struct OverlayChip: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            DonkHaptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                action()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isOn ? .white : DonkColor.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(isOn ? DonkColor.accent : DonkColor.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.donkPressable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct ColorSwatch: View {
    let color: RGBAColor?
    var size: CGFloat = 18
    var radius: CGFloat = 5

    var body: some View {
        ZStack {
            CheckerboardView(cell: max(3, size / 4))
            if let color {
                Rectangle().fill(color.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

struct CheckerboardView: View {
    var cell: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Color(white: 0.76)))
        }
    }
}

// MARK: - Select hint

struct SelectHintBar: View {
    @ObservedObject var controller: InspectorController
    @ObservedObject var settings: InspectorSettingsStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DonkColor.accent)
            Text("Tap or drag over any element")
                .font(.footnote.weight(.medium))
                .foregroundColor(DonkColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            OverlayChip(title: "Outlines", icon: "square.dashed", isOn: settings.settings.outlinesWhileSelecting) {
                controller.toggleOutlinesWhileSelecting()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .inspectorGlassBar(radius: 22)
        .donkInteractive()
    }
}

struct MeasureHintBar: View {
    @ObservedObject var controller: InspectorController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ruler")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Color(CanvasColors.target))
            Text("Tap another element to measure")
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 4)
            OverlayChip(title: "Done", icon: "xmark", isOn: false) {
                controller.toggleMeasuring()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .inspectorGlassBar(radius: 22)
        .donkInteractive()
    }
}

// MARK: - Frames legend

struct FramesLegendBar: View {
    @ObservedObject var settings: InspectorSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch settings.settings.framesPalette {
            case .category:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: 3), alignment: .leading, spacing: 6) {
                    ForEach(ViewCategory.allCases, id: \.rawValue) { category in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color(category.color), lineWidth: 1.5)
                                .frame(width: 12, height: 10)
                            Text(category.title)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                }
            case .depth:
                HStack(spacing: 6) {
                    Text("Depth")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(DonkColor.textSecondary)
                    HStack(spacing: 2) {
                        ForEach(0..<DepthPalette.colors.count, id: \.self) { index in
                            Text("\(index)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color(DepthPalette.colors[index])))
                        }
                    }
                    Text("…")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(DonkColor.textSecondary)
                }
            }
            HStack(spacing: 6) {
                OverlayChip(title: "By kind", icon: "paintpalette", isOn: settings.settings.framesPalette == .category) {
                    settings.settings.framesPalette = settings.settings.framesPalette == .category ? .depth : .category
                }
                OverlayChip(title: "Sizes", icon: "textformat.size", isOn: settings.settings.showsFrameSizes) {
                    settings.settings.showsFrameSizes.toggle()
                }
                Spacer(minLength: 4)
                Label("Touches pass through", systemImage: "hand.point.up.left")
                    .font(.caption2)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .inspectorGlassBar()
        .donkInteractive()
    }
}
