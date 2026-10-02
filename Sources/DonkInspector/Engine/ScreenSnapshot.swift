import UIKit

// MARK: - Loupe

struct LoupeState: Equatable {
    static let span = 11

    var sceneID: ObjectIdentifier
    var point: CGPoint
    var pixelX: Int
    var pixelY: Int
    var colors: [RGBAColor?]
    var isPinned: Bool

    var center: RGBAColor? {
        colors.indices.contains(colors.count / 2) ? colors[colors.count / 2] : nil
    }
}

// MARK: - Snapshot

@MainActor
final class ScreenSnapshot {
    let width: Int
    let height: Int
    let scale: CGFloat
    let date: Date
    private let pixels: [UInt8]

    private init(width: Int, height: Int, scale: CGFloat, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.scale = scale
        self.pixels = pixels
        date = Date()
    }

    static func capture(for overlay: UIWindow) -> ScreenSnapshot? {
        let windows = ViewHierarchy.windowsBackToFront(in: overlay.windowScene)
        let bounds = overlay.bounds
        guard !windows.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = overlay.screen.scale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard let canvas = PixelCanvas(width: width, height: height, scale: scale),
              let scratch = PixelCanvas(width: width, height: height, scale: scale) else { return nil }
        for window in windows {
            let rect = window.frame == overlay.frame ? window.bounds : window.convert(window.bounds, to: overlay)
            let method = SnapshotMethod.preferred(for: window)
            scratch.clear()
            scratch.draw(window, in: rect, method: method)
            if method == .hierarchy, SnapshotMethod.hasContent(window), scratch.isBlank(in: rect) {
                scratch.clear()
                scratch.draw(window, in: rect, method: .layer)
            }
            canvas.composite(scratch)
        }
        return ScreenSnapshot(width: width, height: height, scale: scale, pixels: canvas.bytes())
    }

    func pixelCoordinate(for point: CGPoint) -> (x: Int, y: Int) {
        (Int((point.x * scale).rounded(.down)), Int((point.y * scale).rounded(.down)))
    }

    func color(x: Int, y: Int) -> RGBAColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = (y * width + x) * 4
        let alpha = Double(pixels[index + 3]) / 255
        guard alpha > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return RGBAColor(
            red: Double(pixels[index]) / 255 / alpha,
            green: Double(pixels[index + 1]) / 255 / alpha,
            blue: Double(pixels[index + 2]) / 255 / alpha,
            alpha: alpha
        )
    }

    func loupe(at point: CGPoint, sceneID: ObjectIdentifier, isPinned: Bool) -> LoupeState {
        let center = pixelCoordinate(for: point)
        let radius = LoupeState.span / 2
        var colors: [RGBAColor?] = []
        colors.reserveCapacity(LoupeState.span * LoupeState.span)
        for row in -radius...radius {
            for column in -radius...radius {
                colors.append(color(x: center.x + column, y: center.y + row))
            }
        }
        return LoupeState(sceneID: sceneID, point: point, pixelX: center.x, pixelY: center.y, colors: colors, isPinned: isPinned)
    }
}

// MARK: - Rendering

enum SnapshotMethod: Equatable {
    case hierarchy
    case layer

    @MainActor
    static func preferred(for window: UIWindow) -> SnapshotMethod {
        if let host = window.layer.superlayer?.delegate as? UIView, host !== window, host.isDescendant(of: window) {
            return .layer
        }
        return containsSecureContainer(window) ? .layer : .hierarchy
    }

    @MainActor
    static func hasContent(_ window: UIWindow) -> Bool {
        if let color = window.backgroundColor, color.cgColor.alpha > 0.01 { return true }
        return window.subviews.contains { !$0.isHidden && $0.alpha >= 0.01 && $0.bounds.width > 0 && $0.bounds.height > 0 }
    }

    @MainActor
    static func containsSecureContainer(_ root: UIView) -> Bool {
        var stack: [UIView] = [root]
        var budget = 4000
        while budget > 0, let view = stack.popLast() {
            budget -= 1
            if let field = view as? UITextField, field.isSecureTextEntry, hostsForeignLayer(field) {
                return true
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    @MainActor
    private static func hostsForeignLayer(_ field: UITextField) -> Bool {
        var stack = field.layer.sublayers ?? []
        var budget = 256
        while budget > 0, let layer = stack.popLast() {
            budget -= 1
            if let owner = layer.delegate as? UIView, !owner.isDescendant(of: field) {
                return true
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return false
    }
}

@MainActor
private final class PixelCanvas {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let context: CGContext

    init?(width: Int, height: Int, scale: CGFloat) {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              context.bytesPerRow == width * 4 else { return nil }
        context.interpolationQuality = .none
        self.width = width
        self.height = height
        self.scale = scale
        self.context = context
    }

    func clear() {
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func draw(_ window: UIWindow, in rect: CGRect, method: SnapshotMethod) {
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        switch method {
        case .hierarchy:
            window.drawHierarchy(in: rect, afterScreenUpdates: false)
        case .layer:
            let bounds = window.bounds
            context.translateBy(x: rect.minX, y: rect.minY)
            if bounds.width > 0, bounds.height > 0 {
                context.scaleBy(x: rect.width / bounds.width, y: rect.height / bounds.height)
            }
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            window.layer.render(in: context)
        }
        UIGraphicsPopContext()
        context.restoreGState()
    }

    func isBlank(in rect: CGRect) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let area = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return false }
        let columns = 24
        let rows = 48
        for row in 0..<rows {
            let y = min(height - 1, Int(area.minY + (CGFloat(row) + 0.5) * area.height / CGFloat(rows)))
            for column in 0..<columns {
                let x = min(width - 1, Int(area.minX + (CGFloat(column) + 0.5) * area.width / CGFloat(columns)))
                let index = (y * width + x) * 4
                if bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 {
                    return false
                }
            }
        }
        return true
    }

    func composite(_ other: PixelCanvas) {
        guard let image = other.context.makeImage() else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func bytes() -> [UInt8] {
        guard let data = context.data else { return [UInt8](repeating: 0, count: width * height * 4) }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}
