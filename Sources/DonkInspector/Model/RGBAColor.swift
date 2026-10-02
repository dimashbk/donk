import SwiftUI
import UIKit

struct RGBAColor: Hashable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    init?(_ color: UIColor?, traits: UITraitCollection? = nil) {
        guard let color else { return nil }
        let resolved = traits.map { color.resolvedColor(with: $0) } ?? color
        self.init(cgColor: resolved.cgColor)
    }

    init?(cgColor: CGColor?) {
        guard let cgColor,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components,
              components.count >= 3 else { return nil }
        self.init(
            red: Double(components[0]),
            green: Double(components[1]),
            blue: Double(components[2]),
            alpha: components.count > 3 ? Double(components[3]) : 1
        )
    }

    var red8: Int { Self.byte(red) }
    var green8: Int { Self.byte(green) }
    var blue8: Int { Self.byte(blue) }
    var alpha8: Int { Self.byte(alpha) }

    var isOpaque: Bool { alpha8 == 255 }

    var hex: String {
        if isOpaque {
            return String(format: "#%02X%02X%02X", red8, green8, blue8)
        }
        return String(format: "#%02X%02X%02X%02X", red8, green8, blue8, alpha8)
    }

    var rgbDescription: String {
        if isOpaque {
            return "rgb(\(red8), \(green8), \(blue8))"
        }
        return "rgba(\(red8), \(green8), \(blue8), \(String(format: "%.2f", alpha)))"
    }

    var componentsDescription: String {
        "R \(red8)  G \(green8)  B \(blue8)" + (isOpaque ? "" : "  A \(Int((alpha * 100).rounded()))%")
    }

    var uiKitCode: String {
        String(format: "UIColor(red: %.3f, green: %.3f, blue: %.3f, alpha: %.2f)", red, green, blue, alpha)
    }

    var swiftUICode: String {
        if isOpaque {
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", red, green, blue)
        }
        return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f, opacity: %.2f)", red, green, blue, alpha)
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    var prefersDarkForeground: Bool {
        alpha < 0.4 || luminance > 0.62
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func byte(_ value: Double) -> Int {
        Int((value * 255).rounded())
    }
}
