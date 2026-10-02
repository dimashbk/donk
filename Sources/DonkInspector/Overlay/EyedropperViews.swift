import DonkUI
import SwiftUI

// MARK: - Bar

struct EyedropperBar: View {
    @ObservedObject var controller: InspectorController
    @ObservedObject var settings: InspectorSettingsStore

    private var recent: [RGBAColor] {
        settings.settings.recentColors.compactMap(RGBAColor.init(hex:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ColorSwatch(color: controller.lastPickedColor, size: 34, radius: 9)
                    .overlay(
                        Group {
                            if controller.lastPickedColor == nil {
                                Image(systemName: "eyedropper")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(DonkColor.textSecondary)
                            }
                        }
                    )
                VStack(alignment: .leading, spacing: 2) {
                    if let color = controller.lastPickedColor {
                        Text(color.hex)
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(DonkColor.textPrimary)
                        Text(color.rgbDescription)
                            .font(DonkFont.codeCaption)
                            .foregroundColor(DonkColor.textSecondary)
                    } else {
                        Text("Touch and drag to sample")
                            .font(.subheadline.weight(.semibold))
                        Text("Lift your finger to copy the HEX")
                            .font(.caption)
                            .foregroundColor(DonkColor.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    controller.refreshSnapshotsFromUI()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                        if let date = controller.snapshotDate {
                            Text(DonkFormat.relative(date))
                                .font(.caption2)
                                .foregroundColor(DonkColor.textSecondary)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.donkPressable)
                .foregroundColor(DonkColor.accent)
                .accessibilityLabel("Refresh snapshot")
            }
            if !recent.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(recent, id: \.self) { color in
                                Button {
                                    controller.copyColor(color.hex)
                                } label: {
                                    ColorSwatch(color: color, size: 26, radius: 7)
                                }
                                .buttonStyle(.donkPressable)
                                .accessibilityLabel("Copy \(color.hex)")
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    Button {
                        DonkHaptics.light()
                        withAnimation(InspectorController.modeAnimation) {
                            settings.clearRecentColors()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(DonkColor.textSecondary)
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.donkPressable)
                    .accessibilityLabel("Clear recent colors")
                }
            }
            Label("Secure, DRM-protected or Metal content may sample as black.", systemImage: "info.circle")
                .font(.caption2)
                .foregroundColor(DonkColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 420)
        .inspectorGlassBar()
        .donkInteractive()
    }
}

// MARK: - Loupe

struct LoupeOverlay: View {
    let state: LoupeState

    private static let cell: CGFloat = 12
    private static let infoHeight: CGFloat = 52
    private static let gap: CGFloat = 8
    private static let fingerClearance: CGFloat = 64

    var body: some View {
        GeometryReader { proxy in
            let side = CGFloat(LoupeState.span) * Self.cell
            let total = side + Self.gap + Self.infoHeight
            let width: CGFloat = max(side, 248)
            let center = loupeCenter(in: proxy.size, total: total, width: width)
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 3.5).padding(-1))
                    .frame(width: 24, height: 24)
                    .position(state.point)
                VStack(spacing: Self.gap) {
                    grid(side: side)
                    info
                        .frame(width: width, height: Self.infoHeight)
                }
                .position(center)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.center.map { "Color \($0.hex)" } ?? "No color")
    }

    private func loupeCenter(in size: CGSize, total: CGFloat, width: CGFloat) -> CGPoint {
        var y = state.point.y - Self.fingerClearance - total / 2
        if y - total / 2 < 54 {
            y = state.point.y + Self.fingerClearance + total / 2
        }
        let x = min(max(state.point.x, width / 2 + 8), size.width - width / 2 - 8)
        return CGPoint(x: x, y: min(max(y, total / 2 + 8), size.height - total / 2 - 8))
    }

    private func grid(side: CGFloat) -> some View {
        Canvas { context, size in
            let span = LoupeState.span
            let cell = size.width / CGFloat(span)
            for row in 0..<span {
                for column in 0..<span {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    let index = row * span + column
                    let color = index < state.colors.count ? state.colors[index] : nil
                    if let color, color.isOpaque {
                        context.fill(Path(rect), with: .color(color.color))
                    } else {
                        context.fill(Path(rect), with: .color(Color(white: 0.85)))
                        let half = cell / 2
                        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: half, height: half)), with: .color(Color(white: 0.7)))
                        context.fill(Path(CGRect(x: rect.minX + half, y: rect.minY + half, width: half, height: half)), with: .color(Color(white: 0.7)))
                        if let color {
                            context.fill(Path(rect), with: .color(color.color))
                        }
                    }
                }
            }
            var lines = Path()
            for index in 1..<span {
                let offset = CGFloat(index) * cell
                lines.move(to: CGPoint(x: offset, y: 0))
                lines.addLine(to: CGPoint(x: offset, y: size.height))
                lines.move(to: CGPoint(x: 0, y: offset))
                lines.addLine(to: CGPoint(x: size.width, y: offset))
            }
            context.stroke(lines, with: .color(Color.black.opacity(0.12)), lineWidth: 0.5)
            let middle = CGFloat(span / 2) * cell
            let reticle = CGRect(x: middle, y: middle, width: cell, height: cell)
            context.stroke(Path(reticle.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.75)), lineWidth: 1)
            context.stroke(Path(reticle), with: .color(.white), lineWidth: 1.5)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white, lineWidth: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ColorSwatch(color: state.center, size: 20, radius: 6)
                Text(state.center?.hex ?? "—")
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 6)
                Text("\(UnitFormatter.number(state.point.x)), \(UnitFormatter.number(state.point.y)) pt")
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                Text(state.center?.componentsDescription ?? "Outside snapshot")
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 6)
                Text("\(state.pixelX), \(state.pixelY) px")
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(DonkColor.textSecondary)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(DonkColor.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
    }
}
