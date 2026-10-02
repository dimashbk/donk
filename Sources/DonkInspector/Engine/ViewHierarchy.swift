import DonkUI
import UIKit

// MARK: - Outlines model

struct OutlineLabel: Equatable {
    var origin: CGPoint
    var text: String
    var bucket: Int
}

struct OutlineSet: Equatable {
    var palette: FramesPalette
    var buckets: [[CGRect]]
    var labels: [OutlineLabel]
    var count: Int
}

// MARK: - Hierarchy

@MainActor
enum ViewHierarchy {
    static let outlineLimit = 4000
    static let labelLimit = 140

    static func windowsFrontToBack(in scene: UIWindowScene?) -> [UIWindow] {
        DonkWindowManager.appWindows(in: scene)
            .filter { !$0.isHidden && $0.alpha >= 0.01 }
            .reversed()
    }

    static func windowsBackToFront(in scene: UIWindowScene?) -> [UIWindow] {
        DonkWindowManager.appWindows(in: scene).filter { !$0.isHidden && $0.alpha >= 0.01 }
    }

    static func rect(of view: UIView, in overlay: UIWindow) -> CGRect? {
        guard let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: window)
        if window === overlay { return inWindow }
        if window.frame == overlay.frame, window.screen === overlay.screen { return inWindow }
        return window.convert(inWindow, to: overlay)
    }

    static func isEffectivelyVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return false }
            current = candidate.superview
        }
        return view.window != nil
    }

    // MARK: - Hit testing

    static func hitStack(at point: CGPoint, overlay: UIWindow, includesElements: Bool, reusesElementCache: Bool) -> [InspectorNode] {
        var primary: [[UIView]] = []
        var deferred: [[UIView]] = []
        for window in windowsFrontToBack(in: overlay.windowScene) {
            let local = overlay.convert(point, to: window)
            guard window.bounds.contains(local) else { continue }
            var hits: [UIView] = []
            collect(window, point: local, depth: 0, into: &hits)
            guard !hits.isEmpty else { continue }
            hits = demotingEmptyOverlays(hits)
            if hits.allSatisfy(isVisuallyEmpty) {
                deferred.append(hits)
            } else {
                primary.append(hits)
            }
        }
        let views = (primary + deferred).flatMap { $0 }
        var nodes = views.map(InspectorNode.init(view:))
        guard includesElements,
              let hostIndex = views.firstIndex(where: TypeNaming.isHostingView) else { return nodes }
        let containers = views[...hostIndex].filter(TypeNaming.isSwiftUIInternal)
        let screenPoint = overlay.convert(point, to: overlay.screen.coordinateSpace)
        let elements = AccessibilityElements.nodes(in: containers, containing: screenPoint, reusesCache: reusesElementCache)
        guard !elements.isEmpty else { return nodes }
        let hasEmbeddedUIKit = views[..<hostIndex].contains { !TypeNaming.isSwiftUIInternal($0) }
        nodes.insert(contentsOf: elements, at: hasEmbeddedUIKit ? hostIndex : 0)
        return nodes
    }

    private static func collect(_ view: UIView, point: CGPoint, depth: Int, into hits: inout [UIView]) {
        guard !view.isHidden, view.alpha >= 0.01, depth < 256 else { return }
        let inside = view.bounds.contains(point)
        if !inside, view.clipsToBounds || view.layer.mask != nil { return }
        for subview in view.subviews.reversed() {
            collect(subview, point: subview.convert(point, from: view), depth: depth + 1, into: &hits)
        }
        if inside, !(view is UIWindow), view.bounds.width > 0, view.bounds.height > 0 {
            hits.append(view)
        }
    }

    private static func demotingEmptyOverlays(_ hits: [UIView]) -> [UIView] {
        guard let first = hits.firstIndex(where: { !isVisuallyEmpty($0) }), first > 0 else { return hits }
        let anchor = hits[first]
        var kept: [UIView] = []
        var demoted: [UIView] = []
        for view in hits[..<first] {
            if view.isDescendant(of: anchor) {
                kept.append(view)
            } else {
                demoted.append(view)
            }
        }
        guard !demoted.isEmpty else { return hits }
        return kept + Array(hits[first...]) + demoted
    }

    private static func isVisuallyEmpty(_ view: UIView) -> Bool {
        if view is UILabel || view is UIImageView || view is UIControl || view is UITextView || view is UIScrollView { return false }
        if TypeNaming.isHostingView(view) { return false }
        let layer = view.layer
        if (layer.sublayers?.count ?? 0) > view.subviews.count { return false }
        let backgroundAlpha = view.backgroundColor.map { $0.cgColor.alpha } ?? 0
        return backgroundAlpha < 0.01 && layer.contents == nil && layer.borderWidth == 0 && layer.shadowOpacity == 0
    }

    // MARK: - Outlines

    static func outlines(in overlay: UIWindow, palette: FramesPalette, includesSizes: Bool, formatter: UnitFormatter) -> OutlineSet {
        let bucketCount = DepthPalette.bucketColors(for: palette).count
        var walker = OutlineWalker(
            overlay: overlay,
            palette: palette,
            includesSizes: includesSizes,
            formatter: formatter,
            buckets: Array(repeating: [], count: bucketCount)
        )
        for window in windowsBackToFront(in: overlay.windowScene) {
            walker.walk(window: window)
        }
        return OutlineSet(palette: palette, buckets: walker.buckets, labels: walker.labels, count: walker.count)
    }

    // MARK: - Lookup

    static func view(withIdentifier identifier: String, in scene: UIWindowScene?) -> UIView? {
        for window in windowsFrontToBack(in: scene) {
            if let match = find(identifier, in: window) { return match }
        }
        return nil
    }

    private static func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for subview in view.subviews {
            if let match = find(identifier, in: subview) { return match }
        }
        return nil
    }

    static func ancestors(of view: UIView, limit: Int = 48) -> [UIView] {
        var result: [UIView] = []
        var current = view.superview
        while let candidate = current, result.count < limit {
            result.append(candidate)
            current = candidate.superview
        }
        return result
    }

    static func depth(of view: UIView) -> Int {
        var depth = 0
        var current = view.superview
        while let candidate = current {
            depth += 1
            current = candidate.superview
        }
        return depth
    }
}

// MARK: - Outline walker

@MainActor
private struct OutlineWalker {
    let overlay: UIWindow
    let palette: FramesPalette
    let includesSizes: Bool
    let formatter: UnitFormatter
    var buckets: [[CGRect]]
    var labels: [OutlineLabel] = []
    var count = 0
    private var needsConversion = false
    private weak var currentWindow: UIWindow?

    init(overlay: UIWindow, palette: FramesPalette, includesSizes: Bool, formatter: UnitFormatter, buckets: [[CGRect]]) {
        self.overlay = overlay
        self.palette = palette
        self.includesSizes = includesSizes
        self.formatter = formatter
        self.buckets = buckets
    }

    mutating func walk(window: UIWindow) {
        currentWindow = window
        needsConversion = !(window.frame == overlay.frame && window.screen === overlay.screen)
        let clip = rectInOverlay(window.bounds, of: window, window: window)
        for subview in window.subviews {
            visit(subview, depth: 0, clip: clip)
        }
    }

    private func rectInOverlay(_ rect: CGRect, of view: UIView, window: UIWindow) -> CGRect {
        let inWindow = view === window ? rect : view.convert(rect, to: window)
        return needsConversion ? window.convert(inWindow, to: overlay) : inWindow
    }

    private mutating func visit(_ view: UIView, depth: Int, clip: CGRect) {
        guard count < ViewHierarchy.outlineLimit, !view.isHidden, view.alpha >= 0.01, let window = currentWindow else { return }
        let size = view.bounds.size
        let rect = rectInOverlay(view.bounds, of: view, window: window)
        let visible = rect.intersection(clip)
        if !visible.isNull, visible.width >= 0.5, visible.height >= 0.5, size.width > 0, size.height > 0 {
            let bucket: Int
            switch palette {
            case .depth: bucket = depth % buckets.count
            case .category: bucket = TypeNaming.category(of: view).rawValue
            }
            buckets[bucket].append(visible)
            count += 1
            if includesSizes, size.width > 44, size.height > 44, labels.count < ViewHierarchy.labelLimit,
               !labels.contains(where: { abs($0.origin.x - visible.minX) < 6 && abs($0.origin.y - visible.minY) < 6 }) {
                labels.append(OutlineLabel(origin: visible.origin, text: formatter.size(size), bucket: bucket))
            }
        }
        var childClip = clip
        if view.clipsToBounds || view.layer.mask != nil {
            childClip = visible
        }
        guard !childClip.isNull, !childClip.isEmpty else { return }
        for subview in view.subviews {
            visit(subview, depth: depth + 1, clip: childClip)
        }
    }
}
