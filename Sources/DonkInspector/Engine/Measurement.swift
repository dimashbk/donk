import CoreGraphics

struct DimensionLine: Equatable {
    var start: CGPoint
    var end: CGPoint
    var value: CGFloat
}

struct GuideLine: Equatable {
    var start: CGPoint
    var end: CGPoint
}

struct MeasureValue: Equatable {
    var title: String
    var value: CGFloat
}

enum MeasureRelation: Equatable {
    case selectionInside
    case targetInside
    case disjoint
    case overlapping
    case identical

    var title: String {
        switch self {
        case .selectionInside: return "Selection inside target"
        case .targetInside: return "Target inside selection"
        case .disjoint: return "Separate"
        case .overlapping: return "Overlapping"
        case .identical: return "Same frame"
        }
    }
}

struct MeasureResult: Equatable {
    var relation: MeasureRelation
    var lines: [DimensionLine]
    var guides: [GuideLine]
    var values: [MeasureValue]
}

enum Measurement {
    private static let epsilon: CGFloat = 0.01

    static func insets(of inner: CGRect, in outer: CGRect) -> [DimensionLine] {
        var lines: [DimensionLine] = []
        let top = inner.minY - outer.minY
        let bottom = outer.maxY - inner.maxY
        let left = inner.minX - outer.minX
        let right = outer.maxX - inner.maxX
        if abs(top) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: inner.midX, y: outer.minY), end: CGPoint(x: inner.midX, y: inner.minY), value: top))
        }
        if abs(bottom) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: inner.midX, y: inner.maxY), end: CGPoint(x: inner.midX, y: outer.maxY), value: bottom))
        }
        if abs(left) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: outer.minX, y: inner.midY), end: CGPoint(x: inner.minX, y: inner.midY), value: left))
        }
        if abs(right) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: inner.maxX, y: inner.midY), end: CGPoint(x: outer.maxX, y: inner.midY), value: right))
        }
        return lines
    }

    static func insetValues(of inner: CGRect, in outer: CGRect) -> (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        (inner.minY - outer.minY, inner.minX - outer.minX, outer.maxY - inner.maxY, outer.maxX - inner.maxX)
    }

    static func between(_ selection: CGRect, _ target: CGRect) -> MeasureResult {
        if approximatelyEqual(selection, target) {
            return MeasureResult(relation: .identical, lines: [], guides: [], values: [])
        }
        if contains(target, selection) {
            return nested(inner: selection, outer: target, relation: .selectionInside)
        }
        if contains(selection, target) {
            return nested(inner: target, outer: selection, relation: .targetInside)
        }
        if selection.intersects(target), !selection.intersection(target).isEmpty {
            return overlapping(selection, target)
        }
        return disjoint(selection, target)
    }

    private static func nested(inner: CGRect, outer: CGRect, relation: MeasureRelation) -> MeasureResult {
        let values = insetValues(of: inner, in: outer)
        return MeasureResult(
            relation: relation,
            lines: insets(of: inner, in: outer),
            guides: [],
            values: [
                MeasureValue(title: "Top", value: values.top),
                MeasureValue(title: "Left", value: values.left),
                MeasureValue(title: "Bottom", value: values.bottom),
                MeasureValue(title: "Right", value: values.right),
            ]
        )
    }

    private static func disjoint(_ a: CGRect, _ b: CGRect) -> MeasureResult {
        var lines: [DimensionLine] = []
        var guides: [GuideLine] = []
        var values: [MeasureValue] = []

        if a.maxX <= b.minX || b.maxX <= a.minX {
            let bIsRight = a.maxX <= b.minX
            let x1 = bIsRight ? a.maxX : b.maxX
            let x2 = bIsRight ? b.minX : a.minX
            let overlapTop = max(a.minY, b.minY)
            let overlapBottom = min(a.maxY, b.maxY)
            let y = overlapTop < overlapBottom ? (overlapTop + overlapBottom) / 2 : a.midY
            lines.append(DimensionLine(start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y), value: x2 - x1))
            let edgeX = bIsRight ? b.minX : b.maxX
            if y < b.minY || y > b.maxY {
                let anchorY = y < b.minY ? b.minY : b.maxY
                guides.append(GuideLine(start: CGPoint(x: edgeX, y: anchorY), end: CGPoint(x: edgeX, y: y)))
            }
            values.append(MeasureValue(title: "Horizontal gap", value: x2 - x1))
        }

        if a.maxY <= b.minY || b.maxY <= a.minY {
            let bIsBelow = a.maxY <= b.minY
            let y1 = bIsBelow ? a.maxY : b.maxY
            let y2 = bIsBelow ? b.minY : a.minY
            let overlapLeft = max(a.minX, b.minX)
            let overlapRight = min(a.maxX, b.maxX)
            let x = overlapLeft < overlapRight ? (overlapLeft + overlapRight) / 2 : a.midX
            lines.append(DimensionLine(start: CGPoint(x: x, y: y1), end: CGPoint(x: x, y: y2), value: y2 - y1))
            let edgeY = bIsBelow ? b.minY : b.maxY
            if x < b.minX || x > b.maxX {
                let anchorX = x < b.minX ? b.minX : b.maxX
                guides.append(GuideLine(start: CGPoint(x: anchorX, y: edgeY), end: CGPoint(x: x, y: edgeY)))
            }
            values.append(MeasureValue(title: "Vertical gap", value: y2 - y1))
        }

        return MeasureResult(relation: .disjoint, lines: lines, guides: guides, values: values)
    }

    private static func overlapping(_ a: CGRect, _ b: CGRect) -> MeasureResult {
        let shared = a.intersection(b)
        var lines: [DimensionLine] = []
        var values: [MeasureValue] = []
        let left = b.minX - a.minX
        let right = b.maxX - a.maxX
        let top = b.minY - a.minY
        let bottom = b.maxY - a.maxY
        let midY = shared.midY
        let midX = shared.midX
        if abs(left) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: min(a.minX, b.minX), y: midY - 6), end: CGPoint(x: max(a.minX, b.minX), y: midY - 6), value: abs(left)))
        }
        if abs(right) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: min(a.maxX, b.maxX), y: midY + 6), end: CGPoint(x: max(a.maxX, b.maxX), y: midY + 6), value: abs(right)))
        }
        if abs(top) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: midX - 6, y: min(a.minY, b.minY)), end: CGPoint(x: midX - 6, y: max(a.minY, b.minY)), value: abs(top)))
        }
        if abs(bottom) > epsilon {
            lines.append(DimensionLine(start: CGPoint(x: midX + 6, y: min(a.maxY, b.maxY)), end: CGPoint(x: midX + 6, y: max(a.maxY, b.maxY)), value: abs(bottom)))
        }
        values.append(MeasureValue(title: "Left edges", value: left))
        values.append(MeasureValue(title: "Right edges", value: right))
        values.append(MeasureValue(title: "Top edges", value: top))
        values.append(MeasureValue(title: "Bottom edges", value: bottom))
        values.append(MeasureValue(title: "Overlap width", value: shared.width))
        values.append(MeasureValue(title: "Overlap height", value: shared.height))
        return MeasureResult(relation: .overlapping, lines: lines, guides: [], values: values)
    }

    private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX - epsilon && inner.maxX <= outer.maxX + epsilon
            && inner.minY >= outer.minY - epsilon && inner.maxY <= outer.maxY + epsilon
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < epsilon && abs(a.minY - b.minY) < epsilon
            && abs(a.width - b.width) < epsilon && abs(a.height - b.height) < epsilon
    }
}
