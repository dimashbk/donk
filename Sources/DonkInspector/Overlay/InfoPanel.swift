import DonkUI
import SwiftUI

// MARK: - Panel

struct InfoPanel: View {
    @ObservedObject var controller: InspectorController
    @ObservedObject var settings: InspectorSettingsStore
    let info: InspectorInfo
    let maxHeight: CGFloat
    let isAtTop: Bool
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(DonkColor.textTertiary)
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .accessibilityHidden(true)
                header
                    .padding(.horizontal, 16)
            }
            .contentShape(Rectangle())
            .gesture(panelDrag)
            actions
                .padding(.top, 10)
            if controller.isPanelExpanded {
                Divider()
                    .padding(.top, 10)
                ScrollView {
                    InfoDetails(controller: controller, info: info)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                }
                .frame(maxHeight: maxHeight)
                .transition(.opacity)
            } else {
                Color.clear.frame(height: 12)
            }
        }
        .frame(maxWidth: 560)
        .inspectorPanel()
        .donkInteractive()
        .offset(y: dragOffset)
    }

    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let height = value.translation.height
                let expanding = isAtTop ? height > 0 : height < 0
                dragOffset = expanding ? height * 0.3 : height
            }
            .onEnded { value in
                let distance = value.predictedEndTranslation.height * (isAtTop ? -1 : 1)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                    if distance < -60 {
                        controller.isPanelExpanded = true
                    } else if distance > 60 {
                        if controller.isPanelExpanded {
                            controller.isPanelExpanded = false
                        } else if distance > 180 {
                            controller.clearSelection()
                        }
                    }
                    dragOffset = 0
                }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                DonkIconBadge(info.icon, tone: info.tone, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.title)
                        .font(DonkFont.headline)
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(info.subtitle)
                        .font(DonkFont.caption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge = info.badge {
                        BadgeLabel(text: badge, tone: info.tone == .grpc ? .grpc : .warning, icon: info.tone == .grpc ? "swift" : "eye.slash")
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    DonkHaptics.light()
                    withAnimation(InspectorController.modeAnimation) {
                        controller.clearSelection()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(DonkColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear selection")
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("SIZE")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(DonkColor.textTertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(info.sizeText)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundColor(DonkColor.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(info.unitSuffix)
                            .font(DonkFont.captionEmphasized)
                            .foregroundColor(DonkColor.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                if let insets = info.insets {
                    BoxModelBadge(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
                }
            }
        }
    }

    private var actions: some View {
        ChipRow(spacing: 6, horizontalPadding: 16) {
            FilterChip(
                title: controller.isPanelExpanded ? "Less" : "Details",
                icon: controller.isPanelExpanded ? "chevron.down" : "chevron.up",
                isSelected: controller.isPanelExpanded
            ) {
                controller.isPanelExpanded.toggle()
            }
            FilterChip(
                title: "Underneath",
                icon: "square.stack.3d.down.right",
                isSelected: false,
                count: controller.stack.count > 1 ? controller.stack.count : nil
            ) {
                controller.selectNextUnderneath()
            }
            .disabled(controller.stack.count < 2)
            .opacity(controller.stack.count < 2 ? 0.5 : 1)
            FilterChip(title: "Parent", icon: "arrow.turn.left.up", isSelected: false) {
                controller.selectParent()
            }
            .disabled(info.parents.isEmpty)
            .opacity(info.parents.isEmpty ? 0.5 : 1)
            FilterChip(title: "Measure", icon: "ruler", isSelected: controller.isMeasuring, tone: .info) {
                controller.toggleMeasuring()
            }
            FilterChip(title: "Outlines", icon: "square.dashed", isSelected: settings.settings.outlinesWhileSelecting) {
                controller.toggleOutlinesWhileSelecting()
            }
            FilterChip(title: "Copy", icon: "doc.on.doc", isSelected: false) {
                DonkPasteboard.copy(info.copyText, label: "Element info")
            }
            FilterChip(title: "px", icon: "ruler", isSelected: settings.settings.unit == .pixels) {
                settings.settings.unit = settings.settings.unit == .pixels ? .points : .pixels
            }
            FilterChip(title: "Module", icon: "shippingbox", isSelected: settings.settings.showsModulePrefix) {
                settings.settings.showsModulePrefix.toggle()
            }
        }
    }
}

// MARK: - Badge

private struct BadgeLabel: View {
    let text: String
    let tone: DonkTone
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.softBackground))
    }
}

// MARK: - Box model

struct BoxModelBadge: View {
    let top: String
    let left: String
    let bottom: String
    let right: String

    var body: some View {
        let spacing = Color(CanvasColors.spacing)
        VStack(spacing: 1) {
            value(top, color: spacing)
            HStack(spacing: 4) {
                value(left, color: spacing)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(DonkColor.accent.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(DonkColor.accent, lineWidth: 1.2)
                    )
                    .frame(width: 26, height: 16)
                value(right, color: spacing)
            }
            value(bottom, color: spacing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DonkColor.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Padding to superview: top \(top), left \(left), bottom \(bottom), right \(right)")
    }

    private func value(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// MARK: - Details

private struct InfoDetails: View {
    @ObservedObject var controller: InspectorController
    let info: InspectorInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.isMeasuring {
                measureBox
            }
            ForEach(info.sections) { section in
                InfoSectionBox(title: section.title, icon: section.icon, note: section.note) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        InfoRowView(row: row)
                    }
                }
            }
            InfoSectionBox(title: "Parents", icon: "arrow.turn.left.up", note: nil) {
                if info.parents.isEmpty {
                    emptyRow("No parents")
                } else {
                    ForEach(Array(info.parents.enumerated()), id: \.element.id) { index, link in
                        if index > 0 { Divider() }
                        NodeLinkRow(link: link) {
                            controller.select(link.node)
                        }
                    }
                }
            }
            InfoSectionBox(title: "Children", icon: "arrow.turn.right.down", note: info.hiddenChildren > 0 ? "+\(info.hiddenChildren) more not listed" : nil, count: info.children.count + info.hiddenChildren) {
                if info.children.isEmpty {
                    emptyRow(info.badge == "SwiftUI element (accessibility, partial)" ? "No nested accessibility elements" : "No subviews")
                } else {
                    ForEach(Array(info.children.enumerated()), id: \.element.id) { index, link in
                        if index > 0 { Divider() }
                        NodeLinkRow(link: link) {
                            controller.select(link.node)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var measureBox: some View {
        if let measurement = controller.measurement {
            InfoSectionBox(title: "Measure", icon: "ruler", note: measurement.relation.title, tone: .info) {
                HStack(spacing: 8) {
                    Circle().fill(Color(CanvasColors.target)).frame(width: 8, height: 8)
                    Text(measurement.targetTitle)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Clear") {
                        controller.clearMeasureTarget()
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.vertical, 6)
                ForEach(measurement.rows) { row in
                    Divider()
                    InfoRowView(row: row)
                }
            }
        } else {
            InfoSectionBox(title: "Measure", icon: "ruler", note: nil, tone: .info) {
                Text("Tap another element to see the distance to the selection.")
                    .font(.footnote)
                    .foregroundColor(DonkColor.textSecondary)
                    .padding(.vertical, 6)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(DonkColor.textSecondary)
            .padding(.vertical, 8)
    }
}

struct InfoSectionBox<Content: View>: View {
    let title: String
    let icon: String
    let note: String?
    var count: Int?
    var tone: DonkTone = .accent
    @ViewBuilder let content: () -> Content

    init(title: String, icon: String, note: String?, count: Int? = nil, tone: DonkTone = .accent, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.note = note
        self.count = count
        self.tone = tone
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(tone.color)
                Text(title)
                    .font(DonkFont.rounded(.subheadline, weight: .semibold))
                    .foregroundColor(DonkColor.textPrimary)
                if let count {
                    Text(DonkFormat.compact(count))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(DonkColor.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DonkColor.fill))
                }
                Spacer()
            }
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DonkRadius.medium + 2, style: .continuous)
                .fill(DonkColor.card.opacity(0.92))
        )
    }
}

struct InfoRowView: View {
    let row: InfoRow
    @ScaledMetric(relativeTo: .footnote) private var keyWidth: CGFloat = 104

    var body: some View {
        if row.isColor {
            colorRow
        } else {
            KeyValueRow(key: row.key, value: row.value, monospacedValue: row.isMonospaced, valueTone: row.tone, keyWidth: 104)
        }
    }

    private var colorRow: some View {
        HStack(alignment: .center, spacing: DonkSpacing.m) {
            Text(row.key)
                .font(.footnote.weight(.medium))
                .foregroundColor(DonkColor.textSecondary)
                .frame(width: keyWidth, alignment: .leading)
            if let color = row.color {
                ColorSwatch(color: color, size: 18)
                Text(row.value)
                    .font(DonkFont.code)
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button {
                    DonkPasteboard.copy(color.hex, label: color.hex)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(DonkColor.accent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(color.hex)")
            } else {
                Text("None")
                    .font(.footnote)
                    .foregroundColor(DonkColor.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct NodeLinkRow: View {
    let link: NodeLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: link.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DonkColor.accent)
                    .frame(width: 18)
                Text(link.title)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(link.detail)
                    .font(DonkFont.codeCaption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(DonkColor.textTertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(link.title), \(link.detail)")
        .accessibilityHint("Selects this element")
    }
}
