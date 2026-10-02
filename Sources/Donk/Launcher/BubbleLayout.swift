import CoreGraphics

enum BubbleLayout {
    static let diameter: CGFloat = 56
    static let edgeMargin: CGFloat = 10
    static let verticalMargin: CGFloat = 12
    static let momentum: CGFloat = 0.3

    static var radius: CGFloat { diameter / 2 }

    static func centerBounds(in size: CGSize) -> CGRect {
        let minX = edgeMargin + radius
        let minY = verticalMargin + radius
        let width = max(size.width - 2 * minX, 0)
        let height = max(size.height - 2 * minY, 0)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    static func center(for placement: BubblePlacement, in size: CGSize) -> CGPoint {
        let bounds = centerBounds(in: size)
        let x = placement.edge == .left ? bounds.minX : bounds.maxX
        let y = bounds.minY + bounds.height * CGFloat(placement.verticalFraction)
        return CGPoint(x: x, y: y)
    }

    static func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let bounds = centerBounds(in: size)
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    static func placement(releasedAt point: CGPoint, predicted: CGPoint, in size: CGSize) -> BubblePlacement {
        let bounds = centerBounds(in: size)
        let projectedX = point.x + (predicted.x - point.x) * momentum
        let projectedY = point.y + (predicted.y - point.y) * momentum
        let edge: BubblePlacement.Edge = projectedX < size.width / 2 ? .left : .right
        let fraction: Double
        if bounds.height > 0 {
            fraction = Double((min(max(projectedY, bounds.minY), bounds.maxY) - bounds.minY) / bounds.height)
        } else {
            fraction = 0.5
        }
        return BubblePlacement(edge: edge, verticalFraction: fraction)
    }

    static func menuCenter(menuSize: CGSize, bubbleCenter: CGPoint, edge: BubblePlacement.Edge, in size: CGSize) -> CGPoint {
        let gap: CGFloat = 12
        let halfWidth = menuSize.width / 2
        let halfHeight = menuSize.height / 2
        var x = edge == .right
            ? bubbleCenter.x - radius - gap - halfWidth
            : bubbleCenter.x + radius + gap + halfWidth
        x = min(max(x, halfWidth + edgeMargin), max(size.width - halfWidth - edgeMargin, halfWidth + edgeMargin))
        let minY = halfHeight + verticalMargin
        let maxY = max(size.height - halfHeight - verticalMargin, minY)
        let y = min(max(bubbleCenter.y, minY), maxY)
        return CGPoint(x: x, y: y)
    }
}
