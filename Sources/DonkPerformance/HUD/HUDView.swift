import DonkUI
import SwiftUI

// MARK: - Health

enum FrameHealth {
    static func tone(fps: Double?, target: Int) -> DonkTone {
        guard let fps else { return .neutral }
        let reference = Double(max(target, 1))
        if fps >= reference * 0.9 { return .success }
        if fps >= reference * 0.75 { return .warning }
        return .error
    }

    static func hitchTone(_ ratio: Double?) -> DonkTone {
        guard let ratio else { return .neutral }
        if ratio < 5 { return .success }
        if ratio < 10 { return .warning }
        return .error
    }

    static func cpuTone(_ cpu: Double, threshold: Double = 80) -> DonkTone {
        if cpu >= threshold { return .error }
        if cpu >= threshold * 0.6 { return .warning }
        return .success
    }
}

// MARK: - Root

struct HUDRootView: View {
    @ObservedObject var model: HUDModel
    @State private var pillSize = CGSize(width: 86, height: 40)
    @State private var dragCenter: CGPoint?
    @State private var dragOrigin: CGPoint?

    private let margin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            HUDPill(sample: model.sample, isExpanded: model.isExpanded)
                .background(
                    GeometryReader { pill in
                        Color.clear
                            .onAppear { pillSize = pill.size }
                            .onChange(of: pill.size) { size in pillSize = size }
                    }
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture {
                    model.toggleExpanded()
                }
                .gesture(drag(in: proxy.size))
                .donkInteractive(padding: 4)
                .position(dragCenter ?? restingCenter(in: proxy.size))
        }
        .coordinateSpace(name: HUDRootView.space)
        .ignoresSafeArea(.keyboard)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private static let space = "donk.performance.hud"

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(HUDRootView.space))
            .onChanged { value in
                let origin = dragOrigin ?? restingCenter(in: size)
                if dragOrigin == nil {
                    dragOrigin = origin
                }
                dragCenter = clamp(
                    CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height),
                    in: size
                )
            }
            .onEnded { value in
                let origin = dragOrigin ?? restingCenter(in: size)
                let predicted = CGPoint(
                    x: origin.x + value.predictedEndTranslation.width,
                    y: origin.y + value.predictedEndTranslation.height
                )
                let final = clamp(predicted, in: size)
                let edge: HUDEdge = final.x < size.width / 2 ? .leading : .trailing
                let bounds = verticalBounds(in: size)
                let span = max(1, bounds.upperBound - bounds.lowerBound)
                let fraction = Double((final.y - bounds.lowerBound) / span)
                model.move(to: edge, verticalFraction: fraction)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    dragCenter = nil
                    dragOrigin = nil
                }
                DonkHaptics.light()
            }
    }

    private func restingCenter(in size: CGSize) -> CGPoint {
        let half = pillSize.width / 2
        let x = model.edge == .leading ? margin + half : size.width - margin - half
        let bounds = verticalBounds(in: size)
        let y = bounds.lowerBound + CGFloat(model.verticalFraction) * (bounds.upperBound - bounds.lowerBound)
        return CGPoint(x: x, y: y)
    }

    private func verticalBounds(in size: CGSize) -> ClosedRange<CGFloat> {
        let lower = margin + pillSize.height / 2
        let upper = max(lower, size.height - model.keyboardOverlap - margin - pillSize.height / 2)
        return lower...upper
    }

    private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let half = pillSize.width / 2
        let minX = margin + half
        let maxX = max(minX, size.width - margin - half)
        let bounds = verticalBounds(in: size)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, bounds.lowerBound), bounds.upperBound)
        )
    }
}

// MARK: - Pill

struct HUDPill: View {
    let sample: PerformanceSample?
    let isExpanded: Bool

    private var fps: Double? {
        sample?.fps
    }

    private var fpsTone: DonkTone {
        FrameHealth.tone(fps: fps, target: sample?.targetFPS ?? 60)
    }

    private var fpsText: String {
        fps.map { String(Int($0.rounded())) } ?? "–"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(fpsTone.color)
                    .frame(width: 7, height: 7)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(fpsText)
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundColor(fpsTone == .neutral ? DonkColor.textSecondary : fpsTone.color)
                        .frame(minWidth: 30, alignment: .trailing)
                    Text("FPS")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(DonkColor.textSecondary)
                }
            }
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    row("CPU", value: sample.map { PerformanceText.percent($0.cpu) } ?? "–", tone: sample.map { FrameHealth.cpuTone($0.cpu) } ?? .neutral)
                    row("MEM", value: sample.map { PerformanceText.megabytes($0.footprint) } ?? "–", tone: memoryTone)
                    row("HITCH", value: sample?.hitchRatio.map { PerformanceText.number($0) + " ms/s" } ?? "–", tone: FrameHealth.hitchTone(sample?.hitchRatio))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isExpanded ? 10 : 8)
        .fixedSize()
        .donkGlassBackground(RoundedRectangle(cornerRadius: isExpanded ? 16 : 20, style: .continuous), tint: nil, interactive: true)
        .donkFloatingShadow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame rate")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to \(isExpanded ? "collapse" : "expand"). Drag to move.")
        .accessibilityAddTraits(.isButton)
    }

    private var memoryTone: DonkTone {
        guard let fraction = sample?.memoryUsageFraction else { return .info }
        if fraction >= 0.8 { return .error }
        if fraction >= 0.6 { return .warning }
        return .info
    }

    private var accessibilityValue: String {
        var parts = ["\(fpsText) frames per second"]
        if isExpanded, let sample {
            parts.append("CPU \(PerformanceText.percent(sample.cpu))")
            parts.append("Memory \(PerformanceText.megabytes(sample.footprint))")
        }
        return parts.joined(separator: ", ")
    }

    private func row(_ title: String, value: String, tone: DonkTone) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundColor(DonkColor.textSecondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundColor(tone == .neutral ? DonkColor.textPrimary : tone.color)
                .lineLimit(1)
        }
    }
}
