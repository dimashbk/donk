import DonkCore
import DonkInspector
import DonkUI
import UIKit

@MainActor
struct RemoteUITree {
    static let secureText = RedactionPolicy.defaultReplacement
    static let textLimit = 4096
    static let controllerLimit = 500
    static let controllerDepthLimit = 32

    let options: RemoteTreeOptions
    let space: UICoordinateSpace
    private(set) var nodeCount = 0
    private(set) var isTruncated = false

    init(options: RemoteTreeOptions, space: UICoordinateSpace) {
        self.options = options
        self.space = space
    }

    // MARK: - Document

    static func document(windows candidates: [UIWindow], keyWindow: UIWindow?, screen: UIScreen, options: RemoteTreeOptions) -> JSONValue {
        let windows = includedWindows(candidates)
        var builder = RemoteUITree(options: options, space: screen.coordinateSpace)
        var windowValues: [JSONValue] = []
        for window in windows {
            var object = RemoteObject()
            object.set("class", className(of: window))
            object.set("frame", builder.frame(of: window))
            object.set("level", number: Double(window.windowLevel.rawValue), decimals: 2)
            object.set("isKey", window.isKeyWindow)
            object.set("root", builder.node(for: window, depth: 0))
            windowValues.append(object.value)
        }

        var screenValue = RemoteObject()
        screenValue.set("width", number: Double(screen.bounds.width), decimals: 2)
        screenValue.set("height", number: Double(screen.bounds.height), decimals: 2)
        screenValue.set("scale", number: Double(screen.scale), decimals: 2)

        let appKey = keyWindow.flatMap { windows.contains($0) ? $0 : nil } ?? windows.last { $0.windowLevel == .normal } ?? windows.last
        var result = RemoteObject()
        result.set("screen", screenValue.value)
        if let root = appKey?.rootViewController {
            result.set("topViewController", className(of: topViewController(from: root)))
            var budget = controllerLimit
            result.set("controllers", controllerNode(root, depth: 0, budget: &budget))
        }
        result.set("windows", .array(windowValues))
        result.set("nodeCount", builder.nodeCount)
        result.set("truncated", builder.isTruncated)
        return result.value
    }

    static func includedWindows(_ windows: [UIWindow]) -> [UIWindow] {
        windows.filter { window in
            guard !window.isHidden, window.alpha >= 0.01, window.windowLevel < DonkWindowLevel.inspector else { return false }
            guard !DonkWindowManager.isDonkWindow(window) else { return false }
            return !className(of: window).hasPrefix("Donk") && !TypeNaming.qualifiedName(of: window).hasPrefix("Donk")
        }
    }

    static func className(of object: AnyObject) -> String {
        TypeNaming.displayName(of: object, includesModule: false)
    }

    // MARK: - Views

    mutating func node(for view: UIView, depth: Int) -> JSONValue? {
        guard nodeCount < options.maxNodes else {
            isTruncated = true
            return nil
        }
        let isHidden = Self.isHidden(view)
        guard options.includeHidden || !isHidden else { return nil }
        nodeCount += 1

        var object = RemoteObject()
        object.set("class", Self.className(of: view))
        object.set("frame", frame(of: view))
        let isSecure = Self.isSecure(view)
        object.setNonEmpty("id", view.accessibilityIdentifier)
        object.setNonEmpty("label", Self.limited(view.accessibilityLabel))
        let text = Self.text(of: view, isSecure: isSecure)
        object.setNonEmpty("text", Self.limited(text.value))
        if text.isPlaceholder {
            object.set("placeholder", true)
        }
        let value = view.accessibilityValue.flatMap { $0.isEmpty ? nil : $0 }
        object.setNonEmpty("value", isSecure && value != nil ? Self.secureText : Self.limited(value))
        let traits = RemoteTraits.names(view.accessibilityTraits)
        if !traits.isEmpty {
            object.set("traits", .array(traits.map(JSONValue.string)))
        }
        object.set("interactive", Self.isInteractive(view))
        object.set("hidden", isHidden)
        object.set("alpha", number: Double(view.alpha), decimals: 2)
        if let controller = view.next as? UIViewController, controller.viewIfLoaded === view {
            object.set("viewController", Self.className(of: controller))
        }

        let subviews = view.subviews.filter { options.includeHidden || !Self.isHidden($0) }
        let elements = TypeNaming.isHostingView(view) ? Self.accessibilityChildren(of: view) : []
        let childCount = subviews.count + elements.count
        if childCount > 0 {
            if depth >= options.maxDepth {
                object.set("childrenOmitted", childCount)
            } else {
                var children: [JSONValue] = []
                for subview in subviews {
                    if let child = node(for: subview, depth: depth + 1) {
                        children.append(child)
                    }
                    if isTruncated { break }
                }
                if !isTruncated {
                    for element in elements {
                        if let child = elementNode(for: element, depth: depth + 1) {
                            children.append(child)
                        }
                        if isTruncated { break }
                    }
                }
                if !children.isEmpty {
                    object.set("children", .array(children))
                }
            }
        }
        return object.value
    }

    // MARK: - Accessibility elements

    mutating func elementNode(for element: NSObject, depth: Int) -> JSONValue? {
        guard nodeCount < options.maxNodes else {
            isTruncated = true
            return nil
        }
        let isHidden = element.accessibilityElementsHidden
        guard options.includeHidden || !isHidden else { return nil }
        nodeCount += 1

        var object = RemoteObject()
        object.set("class", "AXElement")
        object.set("frame", Self.frameValue(element.accessibilityFrame))
        object.setNonEmpty("id", AccessibilityElements.identifier(of: element))
        object.setNonEmpty("label", Self.limited(element.accessibilityLabel))
        object.setNonEmpty("value", Self.limited(element.accessibilityValue))
        let traits = RemoteTraits.names(element.accessibilityTraits)
        if !traits.isEmpty {
            object.set("traits", .array(traits.map(JSONValue.string)))
        }
        object.set("interactive", RemoteTraits.isInteractive(element.accessibilityTraits))
        object.set("hidden", isHidden)

        let children = Self.accessibilityChildren(of: element)
        if !children.isEmpty {
            if depth >= options.maxDepth {
                object.set("childrenOmitted", children.count)
            } else {
                var values: [JSONValue] = []
                for child in children {
                    if let value = elementNode(for: child, depth: depth + 1) {
                        values.append(value)
                    }
                    if isTruncated { break }
                }
                if !values.isEmpty {
                    object.set("children", .array(values))
                }
            }
        }
        return object.value
    }

    static func accessibilityChildren(of object: NSObject) -> [NSObject] {
        AccessibilityElements.children(of: object).filter { !($0 is UIView) }
    }

    // MARK: - Fields

    func frame(of view: UIView) -> JSONValue {
        Self.frameValue(view.convert(view.bounds, to: space))
    }

    static func frameValue(_ rect: CGRect) -> JSONValue {
        let rect = rect.isNull || rect.isInfinite ? .zero : rect
        var object = RemoteObject()
        object.set("x", number: Double(rect.minX), decimals: 2)
        object.set("y", number: Double(rect.minY), decimals: 2)
        object.set("width", number: Double(rect.width), decimals: 2)
        object.set("height", number: Double(rect.height), decimals: 2)
        return object.value
    }

    static func isHidden(_ view: UIView) -> Bool {
        view.isHidden || view.alpha < 0.01
    }

    static func isSecure(_ view: UIView) -> Bool {
        if let field = view as? UITextField { return field.isSecureTextEntry }
        if let textView = view as? UITextView { return textView.isSecureTextEntry }
        return false
    }

    static func isInteractive(_ view: UIView) -> Bool {
        guard view.isUserInteractionEnabled else { return false }
        if view is UIControl { return true }
        return view.gestureRecognizers?.contains { $0.isEnabled } ?? false
    }

    static func text(of view: UIView, isSecure: Bool) -> (value: String?, isPlaceholder: Bool) {
        switch view {
        case let label as UILabel:
            return (label.text ?? label.attributedText?.string, false)
        case let button as UIButton:
            return (button.currentTitle ?? button.titleLabel?.text ?? button.configuration?.title, false)
        case let field as UITextField:
            let text = field.text ?? ""
            if !text.isEmpty {
                return (isSecure ? secureText : text, false)
            }
            let placeholder = field.placeholder ?? field.attributedPlaceholder?.string
            return (placeholder, !(placeholder ?? "").isEmpty)
        case let textView as UITextView:
            let text = textView.text ?? ""
            guard !text.isEmpty else { return (nil, false) }
            return (isSecure ? secureText : text, false)
        default:
            return (nil, false)
        }
    }

    static func limited(_ text: String?) -> String? {
        guard let text else { return nil }
        let cut = RemoteJSON.prefix(text, maxBytes: textLimit)
        return cut.isCut ? cut.text + "…" : text
    }

    // MARK: - Controllers

    static func topViewController(from root: UIViewController) -> UIViewController {
        var controller = root
        for _ in 0..<64 {
            if let presented = controller.presentedViewController, !presented.isBeingDismissed {
                controller = presented
            } else if let navigation = controller as? UINavigationController, let top = navigation.topViewController {
                controller = top
            } else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
                controller = selected
            } else if let split = controller as? UISplitViewController, let last = split.viewControllers.last {
                controller = last
            } else if let pages = controller as? UIPageViewController, let first = pages.viewControllers?.first {
                controller = first
            } else {
                break
            }
        }
        return controller
    }

    static func controllerNode(_ controller: UIViewController, depth: Int, budget: inout Int) -> JSONValue {
        budget -= 1
        var object = RemoteObject()
        object.set("class", className(of: controller))
        let navigationTitle = controller.navigationController == nil ? nil : controller.navigationItem.title
        object.setNonEmpty("title", limited(controller.title ?? navigationTitle))
        if depth < controllerDepthLimit {
            var children: [JSONValue] = []
            for child in controller.children where budget > 0 {
                children.append(controllerNode(child, depth: depth + 1, budget: &budget))
            }
            if !children.isEmpty {
                object.set("children", .array(children))
            }
            if budget > 0, let presented = controller.presentedViewController, presented.presentingViewController === controller {
                object.set("presented", controllerNode(presented, depth: depth + 1, budget: &budget))
            }
        }
        return object.value
    }
}

// MARK: - Traits

enum RemoteTraits {
    static func names(_ traits: UIAccessibilityTraits) -> [String] {
        var table: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.searchField, "searchField"),
            (.image, "image"), (.selected, "selected"), (.playsSound, "playsSound"), (.keyboardKey, "keyboardKey"),
            (.staticText, "staticText"), (.summaryElement, "summaryElement"), (.notEnabled, "notEnabled"),
            (.updatesFrequently, "updatesFrequently"), (.startsMediaSession, "startsMediaSession"), (.adjustable, "adjustable"),
            (.allowsDirectInteraction, "allowsDirectInteraction"), (.causesPageTurn, "causesPageTurn"), (.tabBar, "tabBar"),
        ]
        if #available(iOS 17, *) {
            table.append((.toggleButton, "toggleButton"))
            table.append((.supportsZoom, "supportsZoom"))
        }
        return table.filter { traits.contains($0.0) }.map(\.1)
    }

    static func isInteractive(_ traits: UIAccessibilityTraits) -> Bool {
        var interactive: UIAccessibilityTraits = [.button, .link, .adjustable, .searchField, .keyboardKey]
        if #available(iOS 17, *) {
            interactive.insert(.toggleButton)
        }
        return !traits.isDisjoint(with: interactive) && !traits.contains(.notEnabled)
    }
}
