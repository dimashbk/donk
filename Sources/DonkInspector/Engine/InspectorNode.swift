import UIKit

@MainActor
final class InspectorNode: Identifiable, Equatable {
    enum Kind {
        case view
        case element
    }

    nonisolated let id: ObjectIdentifier
    let kind: Kind
    private(set) weak var view: UIView?
    private(set) weak var element: NSObject?
    private(set) weak var host: UIView?
    private var lastScreenFrame: CGRect
    private var cachedSummary: ElementSummary?
    let elementClassName: String?

    init(view: UIView) {
        id = ObjectIdentifier(view)
        kind = .view
        self.view = view
        lastScreenFrame = .null
        elementClassName = nil
    }

    init(element: NSObject, host: UIView, screenFrame: CGRect) {
        id = ObjectIdentifier(element)
        kind = .element
        self.element = element
        self.host = host
        lastScreenFrame = screenFrame
        elementClassName = TypeNaming.qualifiedName(of: element)
        cachedSummary = AccessibilityElements.summary(of: element)
    }

    nonisolated static func == (lhs: InspectorNode, rhs: InspectorNode) -> Bool {
        lhs.id == rhs.id
    }

    var isAlive: Bool {
        switch kind {
        case .view: return view != nil
        case .element: return host?.window != nil
        }
    }

    var window: UIWindow? {
        switch kind {
        case .view: return view?.window
        case .element: return host?.window
        }
    }

    var sceneID: ObjectIdentifier? {
        window?.windowScene.map(ObjectIdentifier.init)
    }

    var contentSize: CGSize {
        switch kind {
        case .view: return view?.bounds.size ?? .zero
        case .element: return currentScreenFrame.size
        }
    }

    var currentScreenFrame: CGRect {
        if kind == .element, let element {
            let frame = element.accessibilityFrame
            if !frame.isNull, !frame.isInfinite, frame.width.isFinite {
                lastScreenFrame = frame
            }
        }
        return lastScreenFrame
    }

    var summary: ElementSummary? {
        if kind == .element, let element {
            cachedSummary = AccessibilityElements.summary(of: element)
        }
        return cachedSummary
    }

    var parent: InspectorNode? {
        switch kind {
        case .view:
            guard let superview = view?.superview else { return nil }
            return InspectorNode(view: superview)
        case .element:
            return host.map(InspectorNode.init(view:))
        }
    }

    func frame(in overlay: UIWindow) -> CGRect? {
        switch kind {
        case .view:
            guard let view else { return nil }
            return ViewHierarchy.rect(of: view, in: overlay)
        case .element:
            guard host?.window != nil else { return nil }
            let frame = currentScreenFrame
            guard !frame.isNull, frame.width.isFinite else { return nil }
            return overlay.convert(frame, from: overlay.screen.coordinateSpace)
        }
    }

    func parentFrame(in overlay: UIWindow) -> CGRect? {
        parent?.frame(in: overlay)
    }
}
