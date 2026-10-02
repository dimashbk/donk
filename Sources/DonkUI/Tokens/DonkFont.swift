import SwiftUI
import UIKit

// MARK: - Typography

public enum DonkFont {
    public static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    public static let title = Font.system(.title2, design: .rounded).weight(.bold)
    public static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
    public static let headline = Font.system(.headline, design: .rounded)
    public static let subheadline = Font.subheadline
    public static let rowTitle = Font.subheadline.weight(.semibold)
    public static let body = Font.body
    public static let callout = Font.callout
    public static let footnote = Font.footnote
    public static let label = Font.footnote.weight(.semibold)
    public static let caption = Font.caption
    public static let captionEmphasized = Font.caption.weight(.semibold)
    public static let caption2 = Font.caption2

    public static let code = Font.system(.footnote, design: .monospaced)
    public static let codeCaption = Font.system(.caption, design: .monospaced)
    public static let codeCaption2 = Font.system(.caption2, design: .monospaced)
    public static let badge = Font.system(.caption2, design: .monospaced).weight(.bold)

    public static let metric = Font.system(.title2, design: .rounded).weight(.semibold).monospacedDigit()
    public static let metricSmall = Font.system(.headline, design: .rounded).weight(.semibold).monospacedDigit()
    public static let number = Font.footnote.monospacedDigit()

    public static func code(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font.system(style, design: .monospaced).weight(weight)
    }

    public static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        Font.system(style, design: .rounded).weight(weight)
    }

    public static func uiCode(_ style: UIFont.TextStyle = .footnote, weight: UIFont.Weight = .regular) -> UIFont {
        let baseTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let baseSize = UIFont.preferredFont(forTextStyle: style, compatibleWith: baseTraits).pointSize
        let font = UIFont.monospacedSystemFont(ofSize: baseSize, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }
}

// MARK: - Spacing

public enum DonkSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let rowVertical: CGFloat = 12
    public static let screen: CGFloat = 16
}

// MARK: - Radius

public enum DonkRadius {
    public static let badge: CGFloat = 6
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let card: CGFloat = 16
    public static let large: CGFloat = 22
}
