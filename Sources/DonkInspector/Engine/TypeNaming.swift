import DonkUI
import UIKit

// MARK: - Type names

@MainActor
enum TypeNaming {
    private static var qualifiedCache: [ObjectIdentifier: String] = [:]
    private static var moduleCache: [ObjectIdentifier: String] = [:]
    private static var categoryCache: [ObjectIdentifier: ViewCategory] = [:]

    static func qualifiedName(of object: AnyObject) -> String {
        let type: AnyClass = Swift.type(of: object)
        let key = ObjectIdentifier(type)
        if let cached = qualifiedCache[key] { return cached }
        let name = clean(_typeName(type, qualified: true))
        qualifiedCache[key] = name
        return name
    }

    static func displayName(of object: AnyObject, includesModule: Bool) -> String {
        let qualified = qualifiedName(of: object)
        return includesModule ? qualified : stripModules(qualified)
    }

    static func moduleName(of object: AnyObject) -> String {
        let type: AnyClass = Swift.type(of: object)
        let key = ObjectIdentifier(type)
        if let cached = moduleCache[key] { return cached }
        let qualified = qualifiedName(of: object)
        let module: String
        if let dot = qualified.firstIndex(of: "."), !qualified[..<dot].contains("<") {
            module = String(qualified[..<dot])
        } else {
            let bundleName = Bundle(for: type).bundleURL.deletingPathExtension().lastPathComponent
            module = bundleName.isEmpty ? "ObjC" : bundleName
        }
        moduleCache[key] = module
        return module
    }

    static func isHostingView(_ view: UIView) -> Bool {
        let name = qualifiedName(of: view)
        return name.contains("HostingView") && (name.hasPrefix("SwiftUI.") || name.hasPrefix("_UIHostingView"))
    }

    static func isSwiftUIInternal(_ view: UIView) -> Bool {
        let name = qualifiedName(of: view)
        return name.hasPrefix("SwiftUI.") || name.hasPrefix("SwiftUICore.")
    }

    static func category(of view: UIView) -> ViewCategory {
        let key = ObjectIdentifier(Swift.type(of: view))
        if let cached = categoryCache[key] { return cached }
        let category: ViewCategory
        switch view {
        case is UILabel, is UITextField, is UITextView: category = .text
        case is UIImageView: category = .image
        case is UIControl: category = .control
        case is UIScrollView: category = .scroll
        default: category = isSwiftUIInternal(view) ? .swiftUI : .container
        }
        categoryCache[key] = category
        return category
    }

    static func stripModules(_ name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        var index = name.startIndex
        var atTokenStart = true
        while index < name.endIndex {
            if atTokenStart {
                atTokenStart = false
                var end = index
                while end < name.endIndex, isIdentifier(name[end]) {
                    end = name.index(after: end)
                }
                if end > index, end < name.endIndex, name[end] == "." {
                    index = name.index(after: end)
                    continue
                }
            }
            let character = name[index]
            result.append(character)
            if "<(,[: ".contains(character) { atTokenStart = true }
            index = name.index(after: index)
        }
        return result
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func clean(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "__C.", with: "")
        while let range = text.range(of: "(unknown context at $") {
            guard let close = text[range.upperBound...].firstIndex(of: ")") else { break }
            var upper = text.index(after: close)
            if upper < text.endIndex, text[upper] == "." { upper = text.index(after: upper) }
            text.removeSubrange(range.lowerBound..<upper)
        }
        return text
    }
}

// MARK: - Categories

enum ViewCategory: Int, CaseIterable {
    case text, image, control, scroll, swiftUI, container

    var title: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .control: return "Control"
        case .scroll: return "Scroll"
        case .swiftUI: return "SwiftUI"
        case .container: return "Container"
        }
    }

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .image: return "photo"
        case .control: return "hand.tap"
        case .scroll: return "scroll"
        case .swiftUI: return "swift"
        case .container: return "square.dashed"
        }
    }

    var tone: DonkTone {
        switch self {
        case .text: return .info
        case .image: return .success
        case .control: return .warning
        case .scroll: return .web
        case .swiftUI: return .grpc
        case .container: return .accent
        }
    }

    var color: UIColor {
        switch self {
        case .text: return UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1)
        case .image: return UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
        case .control: return UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        case .scroll: return UIColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)
        case .swiftUI: return UIColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)
        case .container: return UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1)
        }
    }
}

// MARK: - Depth palette

enum DepthPalette {
    static let colors: [UIColor] = [
        UIColor(red: 0.43, green: 0.36, blue: 0.99, alpha: 1),
        UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1),
        UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1),
        UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1),
        UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1),
        UIColor(red: 0.93, green: 0.28, blue: 0.60, alpha: 1),
        UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),
        UIColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1),
    ]

    static func color(at index: Int) -> UIColor {
        colors[index % colors.count]
    }

    static func bucketColors(for palette: FramesPalette) -> [UIColor] {
        switch palette {
        case .depth: return colors
        case .category: return ViewCategory.allCases.map(\.color)
        }
    }
}
