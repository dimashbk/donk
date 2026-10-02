import SwiftUI
import UIKit

// MARK: - Palette

enum DonkPalette {
    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        let lightColor = UIColor(donkHex: light)
        let darkColor = UIColor(donkHex: dark)
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
    }

    static func soft(_ base: UIColor, light: CGFloat = 0.12, dark: CGFloat = 0.2) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return base.resolvedColor(with: traits).withAlphaComponent(isDark ? dark : light)
        }
    }

    static let accent = dynamic(light: 0x6D5DFC, dark: 0x8B7FFF)
    static let success = dynamic(light: 0x16A34A, dark: 0x22C55E)
    static let warning = dynamic(light: 0xD97706, dark: 0xF59E0B)
    static let error = dynamic(light: 0xDC2626, dark: 0xF87171)
    static let info = dynamic(light: 0x2563EB, dark: 0x60A5FA)
    static let grpc = dynamic(light: 0x9333EA, dark: 0xC084FC)
    static let web = dynamic(light: 0x0D9488, dark: 0x2DD4BF)
    static let neutral = dynamic(light: 0x6B7280, dark: 0x9CA3AF)
    static let patch = dynamic(light: 0xCA8A04, dark: 0xFACC15)

    static let codeKey = dynamic(light: 0x7C3AED, dark: 0xC4B5FD)
    static let codeString = dynamic(light: 0x059669, dark: 0x6EE7B7)
    static let codeNumber = dynamic(light: 0x2563EB, dark: 0x93C5FD)
    static let codeLiteral = dynamic(light: 0xDB2777, dark: 0xF9A8D4)
    static let codePunctuation = UIColor.secondaryLabel

    static let searchMatch = dynamic(light: 0xFDE68A, dark: 0x6B4A0F)
    static let searchCurrent = dynamic(light: 0xFDBA74, dark: 0xC2410C)
    static let segmentIndicator = dynamic(light: 0xFFFFFF, dark: 0x636366)

    static let softAccent = soft(accent)
    static let softSuccess = soft(success)
    static let softWarning = soft(warning)
    static let softError = soft(error)
    static let softInfo = soft(info)
    static let softGrpc = soft(grpc)
    static let softWeb = soft(web)
    static let softNeutral = soft(neutral, light: 0.12, dark: 0.22)

    static func method(_ method: String) -> UIColor {
        switch DonkMethodKind(method) {
        case .get: return info
        case .post: return success
        case .put: return warning
        case .patch: return patch
        case .delete: return error
        case .grpc: return grpc
        case .web: return web
        case .other: return neutral
        }
    }
}

enum DonkMethodKind {
    case get, post, put, patch, delete, grpc, web, other

    init(_ method: String) {
        switch method.uppercased() {
        case "GET": self = .get
        case "POST": self = .post
        case "PUT": self = .put
        case "PATCH": self = .patch
        case "DELETE": self = .delete
        case "WS", "WSS", "WEBSOCKET": self = .web
        case let value where value == "UNARY" || value == "GRPC" || value.contains("STREAM"): self = .grpc
        default: self = .other
        }
    }
}

extension UIColor {
    convenience init(donkHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - SwiftUI colors

public enum DonkColor {
    public static let ui = DonkUIColors()

    public static let accent = Color(uiColor: DonkPalette.accent)
    public static let success = Color(uiColor: DonkPalette.success)
    public static let warning = Color(uiColor: DonkPalette.warning)
    public static let error = Color(uiColor: DonkPalette.error)
    public static let info = Color(uiColor: DonkPalette.info)
    public static let grpc = Color(uiColor: DonkPalette.grpc)
    public static let web = Color(uiColor: DonkPalette.web)
    public static let neutral = Color(uiColor: DonkPalette.neutral)
    public static let patch = Color(uiColor: DonkPalette.patch)

    public static let background = Color(uiColor: .systemGroupedBackground)
    public static let card = Color(uiColor: .secondarySystemGroupedBackground)
    public static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
    public static let fill = Color(uiColor: .tertiarySystemFill)
    public static let separator = Color(uiColor: .separator)

    public static let textPrimary = Color(uiColor: .label)
    public static let textSecondary = Color(uiColor: .secondaryLabel)
    public static let textTertiary = Color(uiColor: .tertiaryLabel)

    public static let codeKey = Color(uiColor: DonkPalette.codeKey)
    public static let codeString = Color(uiColor: DonkPalette.codeString)
    public static let codeNumber = Color(uiColor: DonkPalette.codeNumber)
    public static let codeLiteral = Color(uiColor: DonkPalette.codeLiteral)
    public static let codePunctuation = Color(uiColor: DonkPalette.codePunctuation)
    public static let codeBackground = Color(uiColor: .tertiarySystemGroupedBackground)

    public static let searchMatch = Color(uiColor: DonkPalette.searchMatch)
    public static let searchCurrentMatch = Color(uiColor: DonkPalette.searchCurrent)

    static let segmentIndicator = Color(uiColor: DonkPalette.segmentIndicator)

    public static func method(_ method: String) -> Color {
        switch DonkMethodKind(method) {
        case .get: return info
        case .post: return success
        case .put: return warning
        case .patch: return patch
        case .delete: return error
        case .grpc: return grpc
        case .web: return web
        case .other: return neutral
        }
    }
}

// MARK: - UIKit colors

public struct DonkUIColors: Sendable {
    public var accent: UIColor { DonkPalette.accent }
    public var success: UIColor { DonkPalette.success }
    public var warning: UIColor { DonkPalette.warning }
    public var error: UIColor { DonkPalette.error }
    public var info: UIColor { DonkPalette.info }
    public var grpc: UIColor { DonkPalette.grpc }
    public var web: UIColor { DonkPalette.web }
    public var neutral: UIColor { DonkPalette.neutral }
    public var patch: UIColor { DonkPalette.patch }

    public var background: UIColor { .systemGroupedBackground }
    public var card: UIColor { .secondarySystemGroupedBackground }
    public var elevated: UIColor { .tertiarySystemGroupedBackground }
    public var fill: UIColor { .tertiarySystemFill }
    public var separator: UIColor { .separator }

    public var textPrimary: UIColor { .label }
    public var textSecondary: UIColor { .secondaryLabel }
    public var textTertiary: UIColor { .tertiaryLabel }

    public var codeKey: UIColor { DonkPalette.codeKey }
    public var codeString: UIColor { DonkPalette.codeString }
    public var codeNumber: UIColor { DonkPalette.codeNumber }
    public var codeLiteral: UIColor { DonkPalette.codeLiteral }
    public var codePunctuation: UIColor { DonkPalette.codePunctuation }
    public var codeBackground: UIColor { .tertiarySystemGroupedBackground }

    public var searchMatch: UIColor { DonkPalette.searchMatch }
    public var searchCurrentMatch: UIColor { DonkPalette.searchCurrent }

    public func method(_ method: String) -> UIColor {
        DonkPalette.method(method)
    }
}

// MARK: - Tone

public enum DonkTone: String, CaseIterable, Hashable, Identifiable, Sendable {
    case success
    case warning
    case error
    case info
    case neutral
    case accent
    case grpc
    case web

    public var id: String { rawValue }

    public var color: Color {
        switch self {
        case .success: return DonkColor.success
        case .warning: return DonkColor.warning
        case .error: return DonkColor.error
        case .info: return DonkColor.info
        case .neutral: return DonkColor.neutral
        case .accent: return DonkColor.accent
        case .grpc: return DonkColor.grpc
        case .web: return DonkColor.web
        }
    }

    public var uiColor: UIColor {
        switch self {
        case .success: return DonkPalette.success
        case .warning: return DonkPalette.warning
        case .error: return DonkPalette.error
        case .info: return DonkPalette.info
        case .neutral: return DonkPalette.neutral
        case .accent: return DonkPalette.accent
        case .grpc: return DonkPalette.grpc
        case .web: return DonkPalette.web
        }
    }

    public var softBackground: Color {
        Color(uiColor: softUIBackground)
    }

    public var softUIBackground: UIColor {
        switch self {
        case .success: return DonkPalette.softSuccess
        case .warning: return DonkPalette.softWarning
        case .error: return DonkPalette.softError
        case .info: return DonkPalette.softInfo
        case .neutral: return DonkPalette.softNeutral
        case .accent: return DonkPalette.softAccent
        case .grpc: return DonkPalette.softGrpc
        case .web: return DonkPalette.softWeb
        }
    }

    public var defaultIcon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        case .neutral: return "circle.fill"
        case .accent: return "sparkles"
        case .grpc: return "point.3.connected.trianglepath.dotted"
        case .web: return "globe"
        }
    }

    public static func httpStatus(_ code: Int) -> DonkTone {
        switch code {
        case 200..<300: return .success
        case 100..<200, 300..<400: return .info
        case 400..<500: return .warning
        case 500..<600: return .error
        default: return .neutral
        }
    }

    public static func grpcStatus(_ code: Int) -> DonkTone {
        switch code {
        case 0: return .success
        case 1: return .neutral
        case 3, 5, 6, 7, 9, 11, 12, 16: return .warning
        default: return .error
        }
    }
}
