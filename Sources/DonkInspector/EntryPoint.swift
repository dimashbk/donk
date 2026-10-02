import DonkCore
import DonkUI
import SwiftUI
import UIKit

public enum InspectorMode: String, CaseIterable, Sendable {
    case select, frames, grid, colorPicker
}

public enum DonkInspector {
    @MainActor public static var onWillStart: (() -> Void)? {
        didSet { AccessibilityActivation.recoverIfNeeded() }
    }

    @MainActor public static var onOpenDebugger: (() -> Void)? {
        didSet { AccessibilityActivation.recoverIfNeeded() }
    }

    @MainActor public static func restoreAccessibilityIfNeeded() {
        AccessibilityActivation.recoverIfNeeded()
    }

    @MainActor public static func start(_ mode: InspectorMode) {
        InspectorController.shared.start(mode)
    }

    @MainActor public static func stop() {
        InspectorController.shared.stop()
    }

    @MainActor public static var activeMode: InspectorMode? {
        InspectorController.shared.mode
    }

    @MainActor public static func makeRootView() -> AnyView {
        AnyView(InspectorRootView())
    }

    @MainActor public static var showsOutlinesWhileSelecting: Bool {
        get { InspectorSettingsStore.shared.settings.outlinesWhileSelecting }
        set { InspectorSettingsStore.shared.settings.outlinesWhileSelecting = newValue }
    }

    @MainActor public static var selectedView: UIView? {
        InspectorController.shared.selection?.view
    }

    @MainActor public static func select(view: UIView, expandsPanel: Bool = false) {
        InspectorController.shared.select(view: view, expandsPanel: expandsPanel)
    }

    @MainActor public static func select(at point: CGPoint, expandsPanel: Bool = false) {
        InspectorController.shared.select(at: point, expandsPanel: expandsPanel)
    }

    @MainActor public static func measure(to view: UIView) {
        InspectorController.shared.measure(to: view)
    }

    @MainActor @discardableResult public static func sampleColor(at point: CGPoint) -> String? {
        InspectorController.shared.sampleColor(at: point)
    }
}
