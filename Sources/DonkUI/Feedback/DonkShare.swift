import UIKit

@MainActor
public enum DonkShare {
    public static func share(text: String) {
        share(items: [text])
    }

    public static func share(items: [Any], completion: (() -> Void)? = nil) {
        guard !items.isEmpty else { return }
        guard let presenter = DonkWindowManager.presentingViewController else {
            DonkToast.show("Nothing to present from", tone: .error)
            return
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            completion?()
        }
        if let popover = controller.popoverPresentationController {
            let view = presenter.view ?? UIView()
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        DonkWindowManager.markDonkPresentation(controller)
        presenter.present(controller, animated: true)
    }

    public static func share(fileNamed name: String, data: Data) {
        do {
            let url = try writeTemporaryFile(named: name, data: data)
            share(fileURL: url)
        } catch {
            DonkHaptics.error()
            DonkToast.show("Could not export file", tone: .error)
        }
    }

    public static func share(fileURL: URL) {
        share(items: [fileURL])
    }

    public static func writeTemporaryFile(named name: String, data: Data) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("DonkShare", isDirectory: true)
        try? manager.removeItem(at: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(sanitized(name))
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func sanitized(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "donk-export" }
        return String(cleaned.prefix(120))
    }
}
