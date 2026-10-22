import CoreGraphics
import DonkCore
import DonkInspector
import DonkUI
import UIKit

struct LiveUIProvider: RemoteUIProvider {
    @MainActor func hasForegroundScene() -> Bool {
        DonkWindowManager.activeWindowScene != nil
    }

    @MainActor func tree(_ options: RemoteTreeOptions) throws -> JSONValue {
        let scene = try foregroundScene()
        return RemoteUITree.document(
            windows: DonkWindowManager.appWindows(in: scene),
            keyWindow: DonkWindowManager.appKeyWindow(in: scene),
            screen: scene.screen,
            options: options
        )
    }

    @MainActor func screenshot(scale: CGFloat) throws -> CGImage {
        let scene = try foregroundScene()
        return try Self.composite(DonkWindowManager.appWindows(in: scene), screen: scene.screen, scale: scale)
    }

    @MainActor static func composite(_ candidates: [UIWindow], screen: UIScreen, scale: CGFloat) throws -> CGImage {
        let windows = RemoteUITree.includedWindows(candidates)
        guard !windows.isEmpty else {
            throw RemoteError.unavailable("no visible app windows")
        }
        let space = screen.coordinateSpace
        let image = SnapshotRenderer.image(of: windows, size: screen.bounds.size, scale: scale) { window in
            window.convert(window.bounds, to: space)
        }
        guard let image else {
            throw RemoteError.unavailable("snapshot failed")
        }
        return image
    }

    @MainActor private func foregroundScene() throws -> UIWindowScene {
        guard let scene = DonkWindowManager.activeWindowScene else {
            throw RemoteError.unavailable("no foreground scene")
        }
        return scene
    }
}
