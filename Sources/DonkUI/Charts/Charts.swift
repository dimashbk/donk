import SwiftUI

// MARK: - Sparkline

public struct SparklineView: View {
    private let values: [Double]
    private let range: ClosedRange<Double>?
    private let tone: DonkTone
    private let capacity: Int?
    private let lineWidth: CGFloat
    private let showsFill: Bool
    private let showsLastPoint: Bool

    public init(
        values: [Double],
        range: ClosedRange<Double>? = nil,
        tone: DonkTone = .accent,
        capacity: Int? = nil,
        lineWidth: CGFloat = 1.6,
        showsFill: Bool = true,
        showsLastPoint: Bool = true
    ) {
        self.values = values
        self.range = range
        self.tone = tone
        self.capacity = capacity
        self.lineWidth = lineWidth
        self.showsFill = showsFill
        self.showsLastPoint = showsLastPoint
    }

    public var body: some View {
        GeometryReader { proxy in
            let inset = lineWidth + (showsLastPoint ? 2 : 0)
            let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: inset, dy: inset)
            let resolved = ChartMath.range(for: [values], explicit: range)
            let points = ChartMath.points(values, in: rect, range: resolved, capacity: capacity ?? values.count)
            ZStack(alignment: .topLeading) {
                if points.isEmpty {
                    Path { path in
                        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                    }
                    .stroke(DonkColor.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    if showsFill {
                        ChartMath.areaPath(through: points, baseline: proxy.size.height)
                            .fill(
                                LinearGradient(
                                    colors: [tone.color.opacity(0.28), tone.color.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    ChartMath.smoothPath(through: points)
                        .stroke(tone.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    if showsLastPoint, let last = points.last {
                        Circle()
                            .fill(tone.color)
                            .frame(width: lineWidth * 2.8, height: lineWidth * 2.8)
                            .position(last)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend")
        .accessibilityValue(values.last.map { String(format: "%.1f", $0) } ?? "No data")
    }
}

// MARK: - Line chart

public struct DonkChartSeries: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var values: [Double]
    public var tone: DonkTone

    public init(_ name: String, values: [Double], tone: DonkTone = .accent, id: String? = nil) {
        self.id = id ?? name
        self.name = name
        self.values = values
        self.tone = tone
    }
}

public struct LineChartView: View {
    private let series: [DonkChartSeries]
    private let range: ClosedRange<Double>?
    private let threshold: Double?
    private let unit: String
    private let window: TimeInterval
    private let capacity: Int?
    private let gridLines: Int
    private let showsLegend: Bool
    private let valueFormatter: ((Double) -> String)?

    public init(
        series: [DonkChartSeries],
        range: ClosedRange<Double>? = nil,
        threshold: Double? = nil,
        unit: String = "",
        window: TimeInterval = 60,
        capacity: Int? = nil,
        gridLines: Int = 4,
        showsLegend: Bool = true,
        valueFormatter: ((Double) -> String)? = nil
    ) {
        self.series = series
        self.range = range
        self.threshold = threshold
        self.unit = unit
        self.window = window
        self.capacity = capacity
        self.gridLines = max(1, gridLines)
        self.showsLegend = showsLegend
        self.valueFormatter = valueFormatter
    }

    public init(
        values: [Double],
        tone: DonkTone = .accent,
        name: String = "Value",
        range: ClosedRange<Double>? = nil,
        threshold: Double? = nil,
        unit: String = "",
        window: TimeInterval = 60,
        capacity: Int? = nil,
        valueFormatter: ((Double) -> String)? = nil
    ) {
        self.init(
            series: [DonkChartSeries(name, values: values, tone: tone)],
            range: range,
            threshold: threshold,
            unit: unit,
            window: window,
            capacity: capacity,
            valueFormatter: valueFormatter
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsLegend && series.count > 1 {
                legend
            }
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(minHeight: 150)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map(\.name).joined(separator: ", "))
        .accessibilityValue(accessibilitySummary)
    }

    private var legend: some View {
        HStack(spacing: DonkSpacing.m) {
            ForEach(series) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.tone.color)
                        .frame(width: 7, height: 7)
                    Text(item.name)
                        .font(.caption.weight(.medium))
                        .foregroundColor(DonkColor.textSecondary)
                    if let last = item.values.last {
                        Text(format(last) + unitSuffix)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundColor(DonkColor.textPrimary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var unitSuffix: String {
        guard !unit.isEmpty else { return "" }
        return unit == "%" ? unit : " " + unit
    }

    private var resolvedRange: ClosedRange<Double> {
        ChartMath.range(for: series.map(\.values), explicit: range, threshold: threshold)
    }

    private var slots: Int {
        max(capacity ?? 0, series.map(\.values.count).max() ?? 0, 2)
    }

    private func format(_ value: Double) -> String {
        if let valueFormatter { return valueFormatter(value) }
        let range = resolvedRange
        return ChartMath.defaultLabel(value, span: range.upperBound - range.lowerBound)
    }

    private var accessibilitySummary: String {
        series.compactMap { item in
            item.values.last.map { "\(item.name) \(format($0))\(unitSuffix)" }
        }
        .joined(separator: ", ")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let labelHeight: CGFloat = 14
        let plot = CGRect(x: 0, y: 16, width: size.width, height: max(1, size.height - 16 - labelHeight - 6))
        let range = resolvedRange
        drawGrid(in: &context, plot: plot, range: range)
        drawThreshold(in: &context, plot: plot, range: range)
        drawSeries(in: &context, plot: plot, range: range)
        drawGridLabels(in: &context, plot: plot, range: range)
        drawLatestLabel(in: &context, plot: plot, range: range)
        drawTimeLabels(in: &context, plot: plot, width: size.width)
    }

    private func drawGrid(in context: inout GraphicsContext, plot: CGRect, range: ClosedRange<Double>) {
        for index in 0...gridLines {
            let fraction = CGFloat(index) / CGFloat(gridLines)
            let y = plot.minY + plot.height * fraction
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            let isBaseline = index == gridLines
            context.stroke(
                line,
                with: .color(DonkColor.separator.opacity(isBaseline ? 1 : 0.55)),
                style: StrokeStyle(lineWidth: 0.5, dash: isBaseline ? [] : [3, 4])
            )
        }
    }

    private func drawGridLabels(in context: inout GraphicsContext, plot: CGRect, range: ClosedRange<Double>) {
        let span = range.upperBound - range.lowerBound
        for index in 0...gridLines {
            let fraction = CGFloat(index) / CGFloat(gridLines)
            let y = plot.minY + plot.height * fraction
            let value = range.upperBound - span * Double(fraction)
            let label = context.resolve(
                Text(format(value))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(DonkColor.textSecondary)
            )
            let size = label.measure(in: CGSize(width: plot.width, height: 30))
            let halo = CGRect(x: plot.minX, y: y - 2 - size.height, width: size.width + 6, height: size.height)
            context.fill(Path(roundedRect: halo, cornerRadius: 4, style: .continuous), with: .color(DonkColor.card.opacity(0.82)))
            context.draw(label, at: CGPoint(x: plot.minX + 3, y: y - 2), anchor: .bottomLeading)
        }
    }

    private func drawThreshold(in context: inout GraphicsContext, plot: CGRect, range: ClosedRange<Double>) {
        guard let threshold, range.contains(threshold) else { return }
        let y = ChartMath.y(for: threshold, in: plot, range: range)
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(DonkColor.warning.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        let label = Text(format(threshold) + unitSuffix)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundColor(DonkColor.warning)
        context.draw(label, at: CGPoint(x: plot.midX, y: y - 2), anchor: .bottom)
    }

    private func drawSeries(in context: inout GraphicsContext, plot: CGRect, range: ClosedRange<Double>) {
        for (index, item) in series.enumerated() {
            let points = ChartMath.points(item.values, in: plot, range: range, capacity: slots)
            guard !points.isEmpty else { continue }
            if index == 0 {
                let gradient = Gradient(colors: [item.tone.color.opacity(0.24), item.tone.color.opacity(0)])
                context.fill(
                    ChartMath.areaPath(through: points, baseline: plot.maxY),
                    with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY))
                )
            }
            context.stroke(
                ChartMath.smoothPath(through: points),
                with: .color(item.tone.color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            if let last = points.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 4.5, y: last.y - 4.5, width: 9, height: 9)), with: .color(DonkColor.card))
                context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(item.tone.color))
            }
        }
    }

    private func drawLatestLabel(in context: inout GraphicsContext, plot: CGRect, range: ClosedRange<Double>) {
        guard let primary = series.first, let value = primary.values.last else { return }
        let text = context.resolve(
            Text(format(value) + unitSuffix)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundColor(primary.tone.color)
        )
        let textSize = text.measure(in: CGSize(width: plot.width, height: 40))
        let width = textSize.width + 14
        let height = textSize.height + 4
        let anchorY = ChartMath.y(for: value, in: plot, range: range)
        var originY = anchorY - height - 8
        if originY < 0 {
            originY = anchorY + 8
        }
        let rect = CGRect(x: max(plot.minX, plot.maxX - width - 2), y: originY, width: width, height: height)
        let pill = Path(roundedRect: rect, cornerRadius: height / 2, style: .continuous)
        context.fill(pill, with: .color(DonkColor.card))
        context.fill(pill, with: .color(primary.tone.softBackground))
        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func drawTimeLabels(in context: inout GraphicsContext, plot: CGRect, width: CGFloat) {
        let segments = width > 260 ? 4 : 2
        for index in 0...segments {
            let fraction = Double(index) / Double(segments)
            let x = plot.minX + plot.width * CGFloat(fraction)
            let secondsAgo = window * (1 - fraction)
            let title = index == segments ? "now" : "-" + timeLabel(secondsAgo)
            let anchor: UnitPoint = index == 0 ? .topLeading : (index == segments ? .topTrailing : .top)
            let label = Text(title)
                .font(.caption2.monospacedDigit())
                .foregroundColor(DonkColor.textTertiary)
            context.draw(label, at: CGPoint(x: x, y: plot.maxY + 4), anchor: anchor)
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        if seconds < 120 { return "\(Int(seconds.rounded()))s" }
        if seconds < 7200 { return "\(Int((seconds / 60).rounded()))m" }
        return "\(Int((seconds / 3600).rounded()))h"
    }
}
