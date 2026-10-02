import UIKit

struct ElementSummary: Equatable {
    var label: String?
    var value: String?
    var hint: String?
    var identifier: String?
    var traits: [String]
}

@MainActor
enum AccessibilityElements {
    private struct Entry {
        weak var element: NSObject?
        weak var container: UIView?
        let frame: CGRect
    }

    private struct Cache {
        let key: [ObjectIdentifier]
        let date: CFTimeInterval
        let entries: [Entry]
    }

    private static var cache: Cache?
    private static let nodeBudget = 3000
    private static let depthLimit = 18

    static func nodes(in containers: [UIView], containing screenPoint: CGPoint, reusesCache: Bool) -> [InspectorNode] {
        let entries = collectEntries(in: containers, reusesCache: reusesCache)
        return entries
            .filter { $0.element != nil && $0.container != nil && $0.frame.contains(screenPoint) }
            .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            .compactMap { entry in
                guard let element = entry.element, let container = entry.container else { return nil }
                return InspectorNode(element: element, host: container, screenFrame: entry.frame)
            }
    }

    static func summary(of element: NSObject) -> ElementSummary {
        ElementSummary(
            label: nonEmpty(element.accessibilityLabel),
            value: nonEmpty(element.accessibilityValue),
            hint: nonEmpty(element.accessibilityHint),
            identifier: nonEmpty(identifier(of: element)),
            traits: traitNames(element.accessibilityTraits)
        )
    }

    static func children(of element: NSObject) -> [NSObject] {
        if let elements = element.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { $0 as? NSObject }
        }
        let count = element.accessibilityElementCount()
        guard count > 0, count != NSNotFound, count < 4000 else { return [] }
        return (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
    }

    static func identifier(of object: NSObject) -> String? {
        if let identification = object as? UIAccessibilityIdentification {
            return identification.accessibilityIdentifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() else { return nil }
        return value as? String
    }

    static func traitNames(_ traits: UIAccessibilityTraits) -> [String] {
        let table: [(UIAccessibilityTraits, String)] = [
            (.button, "Button"), (.link, "Link"), (.header, "Header"), (.searchField, "Search field"),
            (.image, "Image"), (.selected, "Selected"), (.playsSound, "Plays sound"), (.keyboardKey, "Keyboard key"),
            (.staticText, "Static text"), (.summaryElement, "Summary"), (.notEnabled, "Not enabled"),
            (.updatesFrequently, "Updates frequently"), (.startsMediaSession, "Starts media"), (.adjustable, "Adjustable"),
            (.allowsDirectInteraction, "Direct interaction"), (.causesPageTurn, "Page turn"), (.tabBar, "Tab bar"),
        ]
        return table.filter { traits.contains($0.0) }.map(\.1)
    }

    private static func collectEntries(in containers: [UIView], reusesCache: Bool) -> [Entry] {
        let now = CACurrentMediaTime()
        let key = containers.map(ObjectIdentifier.init)
        if reusesCache, let cache, cache.key == key, now - cache.date < 1.5 {
            return cache.entries
        }
        var entries: [Entry] = []
        var seen = Set<ObjectIdentifier>()
        var budget = nodeBudget
        for container in containers {
            visit(container, container: container, depth: 0, budget: &budget, seen: &seen, into: &entries)
        }
        cache = Cache(key: key, date: now, entries: entries)
        return entries
    }

    private static func visit(
        _ object: NSObject,
        container: UIView,
        depth: Int,
        budget: inout Int,
        seen: inout Set<ObjectIdentifier>,
        into entries: inout [Entry]
    ) {
        guard depth < depthLimit else { return }
        for element in children(of: object) {
            guard budget > 0 else { return }
            budget -= 1
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            if let view = element as? UIView {
                if !view.isHidden, view.alpha >= 0.01, TypeNaming.isSwiftUIInternal(view) {
                    visit(view, container: view, depth: depth + 1, budget: &budget, seen: &seen, into: &entries)
                    for subview in view.subviews where TypeNaming.isSwiftUIInternal(subview) && !subview.isHidden {
                        visit(subview, container: subview, depth: depth + 1, budget: &budget, seen: &seen, into: &entries)
                    }
                }
                continue
            }
            let frame = element.accessibilityFrame
            if !frame.isNull, !frame.isEmpty, frame.width.isFinite, frame.height.isFinite {
                entries.append(Entry(element: element, container: container, frame: frame))
            }
            visit(element, container: container, depth: depth + 1, budget: &budget, seen: &seen, into: &entries)
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
