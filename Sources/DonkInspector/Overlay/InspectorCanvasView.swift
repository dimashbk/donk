import DonkUI
import UIKit

// MARK: - Scene

struct CanvasLine: Equatable {
    var start: CGPoint
    var end: CGPoint
    var text: String
}

struct CanvasScene: Equatable {
    var outlines: OutlineSet?
    var selectionID: ObjectIdentifier?
    var selection: CGRect?
    var selectionLabel: String?
    var parent: CGRect?
    var target: CGRect?
    var lines: [CanvasLine] = []
    var guides: [GuideLine] = []
}

// MARK: - Palette

enum CanvasColors {
    static let spacing = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.98, green: 0.44, blue: 0.52, alpha: 1)
            : UIColor(red: 0.96, green: 0.25, blue: 0.37, alpha: 1)
    }

    static let target = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1)
            : UIColor(red: 0.05, green: 0.65, blue: 0.91, alpha: 1)
    }
}

// MARK: - Canvas

final class InspectorCanvasView: UIView {
    private let outlinesLayer = CALayer()
    private var bucketLayers: [CAShapeLayer] = []
    private var sizeLabelLayers: [CATextLayer] = []
    private let parentLayer = CAShapeLayer()
    private let selectionHalo = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let targetHalo = CAShapeLayer()
    private let targetLayer = CAShapeLayer()
    private let guidesLayer = CAShapeLayer()
    private let linesLayer = CAShapeLayer()
    private var lineLabels: [CanvasLabelView] = []
    private let sizeBadge = CanvasLabelView()
    private var current = CanvasScene()
    private var outlinePalette: FramesPalette?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        accessibilityElementsHidden = true
        layer.addSublayer(outlinesLayer)
        outlinesLayer.opacity = 0
        for shape in [parentLayer, selectionHalo, selectionLayer, targetHalo, targetLayer, guidesLayer, linesLayer] {
            shape.fillColor = UIColor.clear.cgColor
            shape.opacity = 0
            shape.contentsScale = UIScreen.main.scale
            layer.addSublayer(shape)
        }
        parentLayer.lineWidth = 1
        parentLayer.lineDashPattern = [4, 3]
        selectionLayer.lineWidth = 2
        targetLayer.lineWidth = 2
        selectionHalo.lineWidth = 4.5
        targetHalo.lineWidth = 4.5
        guidesLayer.lineWidth = 1
        guidesLayer.lineDashPattern = [3, 3]
        linesLayer.lineWidth = 1
        addSubview(sizeBadge)
        sizeBadge.alpha = 0
        applyColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        applyColors()
    }

    private func applyColors() {
        let traits = traitCollection
        let accent = DonkColor.ui.accent.resolvedColor(with: traits)
        let spacing = CanvasColors.spacing.resolvedColor(with: traits)
        let target = CanvasColors.target.resolvedColor(with: traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parentLayer.strokeColor = accent.withAlphaComponent(0.6).cgColor
        selectionLayer.strokeColor = accent.cgColor
        selectionLayer.fillColor = accent.withAlphaComponent(0.1).cgColor
        let halo = traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.7) : UIColor.white.withAlphaComponent(0.9)
        selectionHalo.strokeColor = halo.cgColor
        targetHalo.strokeColor = halo.cgColor
        targetLayer.strokeColor = target.cgColor
        targetLayer.fillColor = target.withAlphaComponent(0.1).cgColor
        guidesLayer.strokeColor = spacing.withAlphaComponent(0.7).cgColor
        linesLayer.strokeColor = spacing.cgColor
        CATransaction.commit()
        sizeBadge.fill = accent
        lineLabels.forEach { $0.fill = spacing }
    }

    // MARK: - Apply

    func apply(_ scene: CanvasScene, animated: Bool) {
        guard scene != current else { return }
        let previous = current
        current = scene
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.22 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(!animated)

        if scene.outlines != previous.outlines {
            updateOutlines(scene.outlines)
        }
        outlinesLayer.opacity = scene.outlines == nil ? 0 : 1

        let glides = animated && previous.selection != nil && scene.selection != nil && previous.selectionID != scene.selectionID
        let selectionPath = scene.selection.map { roundedRectPath($0.insetBy(dx: 1, dy: 1)) }
        setPath(selectionHalo, selectionPath, glides: glides)
        setPath(selectionLayer, selectionPath, glides: glides)
        selectionHalo.opacity = scene.selection == nil ? 0 : 1
        selectionLayer.opacity = scene.selection == nil ? 0 : 1
        setPath(parentLayer, scene.parent.map { CGPath(rect: $0.insetBy(dx: 0.5, dy: 0.5), transform: nil) }, glides: glides)
        parentLayer.opacity = scene.parent == nil ? 0 : 1
        let targetPath = scene.target.map { roundedRectPath($0.insetBy(dx: 1, dy: 1)) }
        setPath(targetHalo, targetPath, glides: false)
        setPath(targetLayer, targetPath, glides: false)
        targetHalo.opacity = scene.target == nil ? 0 : 1
        targetLayer.opacity = scene.target == nil ? 0 : 1
        setPath(linesLayer, scene.lines.isEmpty ? nil : dimensionPath(scene.lines), glides: false)
        linesLayer.opacity = scene.lines.isEmpty ? 0 : 1
        setPath(guidesLayer, scene.guides.isEmpty ? nil : guidesPath(scene.guides), glides: false)
        guidesLayer.opacity = scene.guides.isEmpty ? 0 : 1
        CATransaction.commit()

        let occupied = layoutLineLabels(scene)
        layoutSizeBadge(scene, avoiding: occupied, animated: animated)
    }

    private func setPath(_ shape: CAShapeLayer, _ path: CGPath?, glides: Bool) {
        guard let path else { return }
        if glides {
            shape.path = path
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = path
            CATransaction.commit()
        }
    }

    private func roundedRectPath(_ rect: CGRect) -> CGPath {
        let safe = rect.width > 0 && rect.height > 0 ? rect : rect.insetBy(dx: -1, dy: -1)
        let radius = min(3, min(safe.width, safe.height) / 2)
        return CGPath(roundedRect: safe, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func dimensionPath(_ lines: [CanvasLine]) -> CGPath {
        let path = CGMutablePath()
        for line in lines {
            let dx = line.end.x - line.start.x
            let dy = line.end.y - line.start.y
            let length = hypot(dx, dy)
            guard length >= 1 else { continue }
            path.move(to: line.start)
            path.addLine(to: line.end)
            let nx = -dy / length * 4
            let ny = dx / length * 4
            for point in [line.start, line.end] {
                path.move(to: CGPoint(x: point.x + nx, y: point.y + ny))
                path.addLine(to: CGPoint(x: point.x - nx, y: point.y - ny))
            }
        }
        return path
    }

    private func guidesPath(_ guides: [GuideLine]) -> CGPath {
        let path = CGMutablePath()
        for guide in guides {
            path.move(to: guide.start)
            path.addLine(to: guide.end)
        }
        return path
    }

    // MARK: - Outlines

    private func updateOutlines(_ outlines: OutlineSet?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let outlines else { return }
        if outlinePalette != outlines.palette || bucketLayers.count != outlines.buckets.count {
            bucketLayers.forEach { $0.removeFromSuperlayer() }
            bucketLayers = DepthPalette.bucketColors(for: outlines.palette).map { color in
                let shape = CAShapeLayer()
                shape.fillColor = UIColor.clear.cgColor
                shape.strokeColor = color.withAlphaComponent(0.9).cgColor
                shape.lineWidth = 1
                shape.contentsScale = window?.screen.scale ?? UIScreen.main.scale
                outlinesLayer.addSublayer(shape)
                return shape
            }
            outlinePalette = outlines.palette
        }
        for (index, rects) in outlines.buckets.enumerated() where index < bucketLayers.count {
            let path = CGMutablePath()
            for rect in rects {
                path.addRect(rect.insetBy(dx: 0.5, dy: 0.5))
            }
            bucketLayers[index].path = path
        }
        updateSizeLabels(outlines)
    }

    private func updateSizeLabels(_ outlines: OutlineSet) {
        let colors = DepthPalette.bucketColors(for: outlines.palette)
        let font = UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        while sizeLabelLayers.count < outlines.labels.count {
            let text = CATextLayer()
            text.font = font
            text.fontSize = 9
            text.alignmentMode = .center
            text.contentsScale = scale
            text.cornerRadius = 3
            text.masksToBounds = true
            text.foregroundColor = UIColor.white.cgColor
            outlinesLayer.addSublayer(text)
            sizeLabelLayers.append(text)
        }
        for (index, layer) in sizeLabelLayers.enumerated() {
            guard index < outlines.labels.count else {
                layer.isHidden = true
                continue
            }
            let label = outlines.labels[index]
            let size = (label.text as NSString).size(withAttributes: [.font: font])
            layer.isHidden = false
            layer.string = label.text
            layer.backgroundColor = colors[label.bucket % colors.count].withAlphaComponent(0.88).cgColor
            layer.frame = CGRect(x: label.origin.x + 2, y: label.origin.y + 2, width: ceil(size.width) + 6, height: ceil(size.height) + 2)
        }
    }

    // MARK: - Labels

    @discardableResult
    private func layoutLineLabels(_ scene: CanvasScene) -> [CGRect] {
        let spacing = CanvasColors.spacing.resolvedColor(with: traitCollection)
        while lineLabels.count < scene.lines.count {
            let label = CanvasLabelView()
            label.fill = spacing
            addSubview(label)
            lineLabels.append(label)
        }
        var occupied: [CGRect] = []
        for (index, label) in lineLabels.enumerated() {
            guard index < scene.lines.count else {
                label.isHidden = true
                continue
            }
            let line = scene.lines[index]
            label.isHidden = false
            label.text = line.text
            let size = label.intrinsicContentSize
            var center = CGPoint(x: (line.start.x + line.end.x) / 2, y: (line.start.y + line.end.y) / 2)
            let horizontal = abs(line.end.x - line.start.x) >= abs(line.end.y - line.start.y)
            let length = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            let along = horizontal ? size.width : size.height
            if length < along + 6 {
                if horizontal {
                    center.y -= size.height / 2 + 5
                } else {
                    center.x += size.width / 2 + 6
                }
            }
            var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            for other in occupied where other.intersects(frame) {
                if horizontal {
                    frame.origin.y = other.maxY + 2
                } else {
                    frame.origin.x = other.maxX + 2
                }
            }
            frame = clamp(frame)
            occupied.append(frame)
            label.frame = frame.integral
        }
        for line in scene.lines {
            let minX = min(line.start.x, line.end.x)
            let minY = min(line.start.y, line.end.y)
            let segment = CGRect(x: minX, y: minY, width: abs(line.end.x - line.start.x), height: abs(line.end.y - line.start.y))
            occupied.append(segment.insetBy(dx: -5, dy: -5))
        }
        return occupied
    }

    private func layoutSizeBadge(_ scene: CanvasScene, avoiding occupied: [CGRect], animated: Bool) {
        guard let rect = scene.selection, let text = scene.selectionLabel else {
            animateBadge(alpha: 0, animated: animated)
            return
        }
        sizeBadge.text = text
        let size = sizeBadge.intrinsicContentSize
        let below = rect.maxY + 6
        let above = rect.minY - size.height - 6
        let candidates = [
            CGPoint(x: rect.midX - size.width / 2, y: below),
            CGPoint(x: rect.maxX - size.width, y: below),
            CGPoint(x: rect.minX, y: below),
            CGPoint(x: rect.midX - size.width / 2, y: above),
            CGPoint(x: rect.maxX - size.width, y: above),
            CGPoint(x: rect.minX, y: above),
            CGPoint(x: rect.maxX - size.width - 4, y: rect.maxY - size.height - 4),
        ]
        let usable = bounds.inset(by: UIEdgeInsets(top: safeAreaInsets.top + 2, left: 2, bottom: safeAreaInsets.bottom + 2, right: 2))
        let frames = candidates.map { CGRect(origin: $0, size: size) }
        let chosen = frames.first { frame in
            usable.contains(frame) && !occupied.contains { $0.intersects(frame) }
        } ?? frames.first { usable.contains($0) } ?? frames[0]
        sizeBadge.frame = clamp(chosen).integral
        animateBadge(alpha: 1, animated: animated)
    }

    private func animateBadge(alpha: CGFloat, animated: Bool) {
        guard sizeBadge.alpha != alpha else { return }
        if animated {
            UIView.animate(withDuration: 0.2) { self.sizeBadge.alpha = alpha }
        } else {
            sizeBadge.alpha = alpha
        }
    }

    private func clamp(_ frame: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(max(result.origin.x, 2), max(2, bounds.width - result.width - 2))
        result.origin.y = min(max(result.origin.y, 2), max(2, bounds.height - result.height - 2))
        return result
    }
}

// MARK: - Label view

final class CanvasLabelView: UIView {
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set {
            guard label.text != newValue else { return }
            label.text = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var fill: UIColor = .systemPink {
        didSet { backgroundColor = fill }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        backgroundColor = fill
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        let size = label.intrinsicContentSize
        return CGSize(width: ceil(size.width) + 10, height: ceil(size.height) + 4)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.cornerRadius = bounds.height / 2
    }
}
