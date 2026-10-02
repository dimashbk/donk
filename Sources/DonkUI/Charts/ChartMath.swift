import SwiftUI

enum ChartMath {
    static func range(for series: [[Double]], explicit: ClosedRange<Double>?, threshold: Double? = nil) -> ClosedRange<Double> {
        if let explicit, explicit.upperBound > explicit.lowerBound {
            return explicit
        }
        var minValue = Double.infinity
        var maxValue = -Double.infinity
        for values in series {
            for value in values where value.isFinite {
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
            }
        }
        if let threshold, threshold.isFinite {
            minValue = min(minValue, threshold)
            maxValue = max(maxValue, threshold)
        }
        guard minValue.isFinite, maxValue.isFinite else { return 0...1 }
        if minValue == maxValue {
            let pad = max(abs(minValue) * 0.1, 1)
            let lower = minValue >= 0 ? max(0, minValue - pad) : minValue - pad
            return lower...(maxValue + pad)
        }
        let pad = (maxValue - minValue) * 0.12
        var lower = minValue - pad
        if minValue >= 0, lower < 0 {
            lower = 0
        }
        return lower...(maxValue + pad)
    }

    static func points(_ values: [Double], in rect: CGRect, range: ClosedRange<Double>, capacity: Int) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let slots = max(capacity, values.count, 2)
        let step = rect.width / CGFloat(slots - 1)
        let span = range.upperBound - range.lowerBound
        let offset = slots - values.count
        var result: [CGPoint] = []
        result.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let safe = value.isFinite ? value : range.lowerBound
            let clamped = min(max(safe, range.lowerBound), range.upperBound)
            let ratio = span > 0 ? (clamped - range.lowerBound) / span : 0.5
            result.append(CGPoint(x: rect.minX + CGFloat(offset + index) * step, y: rect.maxY - CGFloat(ratio) * rect.height))
        }
        if result.count == 1, let only = result.first {
            result.insert(CGPoint(x: rect.minX, y: only.y), at: 0)
        }
        return result
    }

    static func y(for value: Double, in rect: CGRect, range: ClosedRange<Double>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return rect.midY }
        let ratio = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span
        return rect.maxY - CGFloat(ratio) * rect.height
    }

    static func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let count = points.count
        guard count > 2 else {
            if count == 2 { path.addLine(to: points[1]) }
            return path
        }
        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            slopes[index] = dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            let left = slopes[index - 1]
            let right = slopes[index]
            tangents[index] = left * right <= 0 ? 0 : (left + right) / 2
        }
        for index in 0..<(count - 1) {
            let slope = slopes[index]
            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let alpha = tangents[index] / slope
            let beta = tangents[index + 1] / slope
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let factor = 3 / magnitude.squareRoot()
                tangents[index] = factor * alpha * slope
                tangents[index + 1] = factor * beta * slope
            }
        }
        for index in 0..<(count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let third = (end.x - start.x) / 3
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + third, y: start.y + tangents[index] * third),
                control2: CGPoint(x: end.x - third, y: end.y - tangents[index + 1] * third)
            )
        }
        return path
    }

    static func areaPath(through points: [CGPoint], baseline: CGFloat) -> Path {
        guard let first = points.first, let last = points.last else { return Path() }
        var path = smoothPath(through: points)
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.addLine(to: CGPoint(x: first.x, y: baseline))
        path.closeSubpath()
        return path
    }

    static func defaultLabel(_ value: Double, span: Double) -> String {
        guard value.isFinite else { return "–" }
        let magnitude = abs(value)
        if magnitude >= 10_000 { return DonkFormat.compact(Int(value.rounded())) }
        if span < 2 { return String(format: "%.2f", value) }
        if span < 20 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }
}
