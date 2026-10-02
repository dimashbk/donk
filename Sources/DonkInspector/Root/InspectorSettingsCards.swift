import DonkUI
import SwiftUI

// MARK: - General

struct GeneralSettingsCard: View {
    @ObservedObject var settings: InspectorSettingsStore

    var body: some View {
        DonkCard(title: "Select & info panel", icon: "cursorarrow.rays") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Units")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(DonkColor.textSecondary)
                SegmentedTabs(
                    selection: settings.binding(\.unit),
                    tabs: MeasureUnit.allCases,
                    title: { $0 == .points ? "Points (pt)" : "Pixels (px)" }
                )
            }
            VStack(spacing: 0) {
                ToggleRow(icon: "shippingbox", tone: .accent, title: "Module prefix", subtitle: "Show “UIKitCore.UILabel” instead of “UILabel”", isOn: settings.binding(\.showsModulePrefix))
                Divider()
                ToggleRow(icon: "rectangle.expand.vertical", tone: .info, title: "Open panel expanded", subtitle: "Show all details right after selecting", isOn: settings.binding(\.opensPanelExpanded))
                Divider()
                swiftUIElementsRow
                Divider()
                ToggleRow(icon: "square.dashed", tone: .web, title: "Outline all while selecting", subtitle: "Combine Frames with Select", isOn: settings.binding(\.outlinesWhileSelecting))
            }
        }
    }
}

extension GeneralSettingsCard {
    @ViewBuilder
    private var swiftUIElementsRow: some View {
        if AccessibilityActivation.isAvailable {
            ToggleRow(
                icon: "swift",
                tone: .grpc,
                title: "Include SwiftUI elements",
                subtitle: "Turns on the accessibility runtime while selecting",
                isOn: settings.binding(\.includesSwiftUIElements)
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ToggleRow(
                    icon: "swift",
                    tone: .grpc,
                    title: "Include SwiftUI elements",
                    subtitle: "Turns on the accessibility runtime while selecting",
                    isOn: .constant(false)
                )
                .disabled(true)
                Text(AccessibilityActivation.isCompiledIn
                     ? "Unavailable: libAccessibility couldn't be loaded on this system."
                     : "Unavailable in this build. Compile DonkInspector with DEBUG or the DONK_PRIVATE_API flag to enable it.")
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Frames

struct FramesSettingsCard: View {
    @ObservedObject var settings: InspectorSettingsStore

    var body: some View {
        DonkCard(title: "Frames", icon: "square.dashed", tone: .info) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Palette")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(DonkColor.textSecondary)
                SegmentedTabs(
                    selection: settings.binding(\.framesPalette),
                    tabs: FramesPalette.allCases,
                    title: { $0 == .depth ? "By depth" : "By kind" }
                )
            }
            legend
            ToggleRow(icon: "textformat.size", tone: .info, title: "Size labels", subtitle: "Label views larger than 44 × 44 pt", isOn: settings.binding(\.showsFrameSizes))
        }
    }

    @ViewBuilder
    private var legend: some View {
        switch settings.settings.framesPalette {
        case .depth:
            HStack(spacing: 3) {
                ForEach(0..<DepthPalette.colors.count, id: \.self) { index in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color(DepthPalette.colors[index]), lineWidth: 2)
                            .frame(height: 18)
                        Text("\(index)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundColor(DonkColor.textSecondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Eight colors by nesting depth, repeating")
        case .category:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                ForEach(ViewCategory.allCases, id: \.rawValue) { category in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color(category.color), lineWidth: 2)
                            .frame(width: 16, height: 12)
                        Text(category.title)
                            .font(.caption.weight(.medium))
                            .foregroundColor(DonkColor.textPrimary)
                    }
                }
            }
        }
    }
}

// MARK: - Grid

struct GridSettingsCard: View {
    @ObservedObject var settings: InspectorSettingsStore
    @FocusState private var focused: GridField?

    private var grid: GridSettings { settings.settings.grid }

    var body: some View {
        DonkCard(title: "Grid defaults", icon: "squareshape.split.3x3", tone: .warning) {
            GridCanvasView(grid: grid)
                .frame(height: 96)
                .background(DonkColor.elevated)
                .clipShape(RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DonkRadius.medium, style: .continuous)
                        .strokeBorder(DonkColor.separator, lineWidth: 0.5)
                )
            ChipRow(spacing: 6, horizontalPadding: 0) {
                ForEach(GridPreset.all) { preset in
                    FilterChip(title: preset.title, icon: preset.icon, isSelected: preset.matches(grid)) {
                        settings.apply(preset)
                    }
                }
            }
            VStack(spacing: 0) {
                numberRow("Cell width", field: .cellWidth, value: grid.cellWidth) { settings.setCellWidth($0) }
                Divider()
                numberRow("Cell height", field: .cellHeight, value: grid.cellHeight) { settings.setCellHeight($0) }
                Divider()
                ToggleRow(icon: "link", tone: .warning, title: "Square cells", subtitle: "Keep width and height equal", isOn: Binding(
                    get: { grid.isLinked },
                    set: { value in
                        settings.updateGrid { grid in
                            grid.isLinked = value
                            if value { grid.cellHeight = grid.cellWidth }
                        }
                    }
                ))
                Divider()
                ToggleRow(icon: "arrow.left.and.right", tone: .warning, title: "Vertical lines", subtitle: nil, isOn: gridBinding(\.showsVerticalLines))
                Divider()
                ToggleRow(icon: "arrow.up.and.down", tone: .warning, title: "Horizontal lines", subtitle: nil, isOn: gridBinding(\.showsHorizontalLines))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(DonkColor.textSecondary)
                HStack(spacing: 10) {
                    ForEach(GridSettings.palette, id: \.self) { hex in
                        let isSelected = hex.caseInsensitiveCompare(grid.colorHex) == .orderedSame
                        Button {
                            DonkHaptics.selection()
                            settings.updateGrid { $0.colorHex = hex }
                        } label: {
                            Circle()
                                .fill(RGBAColor(hex: hex)?.color ?? .clear)
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(DonkColor.card, lineWidth: isSelected ? 2.5 : 0))
                                .overlay(Circle().strokeBorder(DonkColor.textPrimary.opacity(isSelected ? 0.7 : 0), lineWidth: 1.5).padding(-2.5))
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
            VStack(spacing: 0) {
                numberRow("Offset X", field: .offsetX, value: grid.offsetX) { value in settings.updateGrid { $0.offsetX = value } }
                Divider()
                numberRow("Offset Y", field: .offsetY, value: grid.offsetY) { value in settings.updateGrid { $0.offsetY = value } }
                Divider()
                ToggleRow(icon: "rectangle.split.3x1", tone: .warning, title: "Columns", subtitle: "Column layout with margin and gutter", isOn: gridBinding(\.columns.isEnabled))
                if grid.columns.isEnabled {
                    Divider()
                    Stepper(value: Binding(
                        get: { grid.columns.count },
                        set: { value in settings.updateGrid { $0.columns.count = value } }
                    ), in: 1...24) {
                        HStack {
                            Text("Count").font(.subheadline)
                            Spacer()
                            Text("\(grid.columns.count)")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                    numberRow("Margin", field: .margin, value: grid.columns.margin) { value in settings.updateGrid { $0.columns.margin = value } }
                    Divider()
                    numberRow("Gutter", field: .gutter, value: grid.columns.gutter) { value in settings.updateGrid { $0.columns.gutter = value } }
                    Divider()
                    ToggleRow(icon: "square.fill.on.square.fill", tone: .warning, title: "Filled columns", subtitle: nil, isOn: gridBinding(\.columns.isFilled))
                }
            }
        } accessory: {
            Button("Reset") {
                DonkHaptics.light()
                focused = nil
                settings.resetGrid()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
                    .font(.body.weight(.semibold))
            }
        }
    }

    private func gridBinding(_ keyPath: WritableKeyPath<GridSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.settings.grid[keyPath: keyPath] },
            set: { value in settings.updateGrid { $0[keyPath: keyPath] = value } }
        )
    }

    private func numberRow(_ title: String, field: GridField, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            TextField("0", value: Binding(get: { value }, set: { set($0) }), format: .number.precision(.fractionLength(0...2)))
                .keyboardType(field.range.lowerBound < 0 ? .numbersAndPunctuation : .decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(width: 72)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: DonkRadius.small, style: .continuous).fill(DonkColor.fill))
                .focused($focused, equals: field)
                .submitLabel(.done)
            Text(field.unit)
                .font(.caption)
                .foregroundColor(DonkColor.textSecondary)
                .frame(width: 18, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent colors

struct RecentColorsCard: View {
    @ObservedObject var settings: InspectorSettingsStore

    private var colors: [RGBAColor] {
        settings.settings.recentColors.compactMap(RGBAColor.init(hex:))
    }

    var body: some View {
        DonkCard(title: "Recent colors", icon: "eyedropper.halffull", tone: .success) {
            if colors.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "eyedropper")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(DonkTone.success.color)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(DonkTone.success.softBackground))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No colors yet")
                            .font(.subheadline.weight(.semibold))
                        Text("Colors you pick with the eyedropper show up here.")
                            .font(.caption)
                            .foregroundColor(DonkColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 12) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            DonkPasteboard.copy(color.hex, label: color.hex)
                        } label: {
                            VStack(spacing: 5) {
                                ColorSwatch(color: color, size: 44, radius: 12)
                                Text(color.hex)
                                    .font(DonkFont.codeCaption2)
                                    .foregroundColor(DonkColor.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.donkPressable)
                        .contextMenu {
                            Button { DonkPasteboard.copy(color.hex, label: "HEX") } label: { Label("Copy HEX", systemImage: "number") }
                            Button { DonkPasteboard.copy(color.rgbDescription, label: "RGB") } label: { Label("Copy RGB", systemImage: "slider.horizontal.3") }
                            Button { DonkPasteboard.copy(color.uiKitCode, label: "UIColor") } label: { Label("Copy UIColor", systemImage: "chevron.left.forwardslash.chevron.right") }
                            Button { DonkPasteboard.copy(color.swiftUICode, label: "Color") } label: { Label("Copy SwiftUI Color", systemImage: "swift") }
                            Button(role: .destructive) { settings.removeRecentColor(color.hex) } label: { Label("Remove", systemImage: "trash") }
                        }
                        .accessibilityLabel("Copy \(color.hex)")
                    }
                }
            }
        } accessory: {
            if !colors.isEmpty {
                Button("Clear") {
                    DonkHaptics.light()
                    withAnimation { settings.clearRecentColors() }
                }
            }
        }
    }
}

// MARK: - Toggle row

struct ToggleRow: View {
    let icon: String
    let tone: DonkTone
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { value in
                DonkHaptics.selection()
                isOn = value
            }
        )) {
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge(icon, tone: tone, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(DonkColor.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(DonkColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(DonkColor.accent)
        .padding(.vertical, 8)
    }
}
