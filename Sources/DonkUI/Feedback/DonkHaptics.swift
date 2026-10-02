import UIKit
import UniformTypeIdentifiers

// MARK: - Haptics

public enum DonkHaptics {
    @MainActor public static var isEnabled = true

    public static func light() {
        impact(.light)
    }

    public static func medium() {
        impact(.medium)
    }

    public static func rigid() {
        impact(.rigid)
    }

    public static func success() {
        notify(.success)
    }

    public static func warning() {
        notify(.warning)
    }

    public static func error() {
        notify(.error)
    }

    public static func selection() {
        DonkMain.run {
            guard isEnabled else { return }
            HapticEngine.selection.selectionChanged()
        }
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        DonkMain.run {
            guard isEnabled else { return }
            HapticEngine.impact(style).impactOccurred()
        }
    }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        DonkMain.run {
            guard isEnabled else { return }
            HapticEngine.notification.notificationOccurred(type)
        }
    }
}

@MainActor
private enum HapticEngine {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let medium = UIImpactFeedbackGenerator(style: .medium)
    static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    static let selection = UISelectionFeedbackGenerator()
    static let notification = UINotificationFeedbackGenerator()

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        switch style {
        case .medium, .heavy: return medium
        case .rigid: return rigid
        default: return light
        }
    }
}

// MARK: - Pasteboard

public enum DonkPasteboard {
    public static let expiration: TimeInterval = 10 * 60

    public static func copy(_ text: String, label: String? = nil, showsToast: Bool = true) {
        DonkMain.run {
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: options)
        }
        DonkHaptics.light()
        guard showsToast else { return }
        let message = label.map { "\($0) copied" } ?? "Copied"
        DonkToast.show(message, icon: "doc.on.doc.fill", tone: .success, duration: 1.4)
    }

    static var options: [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: Date().addingTimeInterval(expiration)]
    }
}
