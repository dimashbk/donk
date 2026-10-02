import DonkCore
import DonkUI
import SwiftUI

enum FilePreviewRoute: Equatable {
    case text(json: Bool)
    case plist
    case image
    case sqlite
    case quickLook
    case hex

    static let textLimit: Int64 = 16 * 1024 * 1024

    static func route(for kind: FileKind, size: Int64) -> FilePreviewRoute {
        switch kind {
        case .text: return size > textLimit ? .hex : .text(json: false)
        case .json: return size > textLimit ? .hex : .text(json: true)
        case .plist: return size > textLimit ? .hex : .plist
        case .image: return .image
        case .sqlite: return .sqlite
        case .pdf, .video, .audio, .archive, .document: return .quickLook
        case .binary, .folder: return .hex
        }
    }
}

@MainActor
final class FilePreviewLoader: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(FilePreviewRoute, kind: FileKind, size: Int64)
        case failed(String)
    }

    let url: URL
    @Published private(set) var state: State = .loading

    init(url: URL) {
        self.url = url
    }

    func load() async {
        guard state == .loading else { return }
        let url = self.url
        let result = await Task.detached(priority: .userInitiated) { () -> State in
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                return .failed("The file doesn't exist or can't be read.")
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let kind = FileKind.detect(url: url)
            return .ready(FilePreviewRoute.route(for: kind, size: size), kind: kind, size: size)
        }.value
        state = result
    }

    func fallBack(to route: FilePreviewRoute) {
        guard case let .ready(_, kind, size) = state else { return }
        state = .ready(route, kind: kind, size: size)
    }
}

struct FilePreviewView: View {
    let url: URL
    let isProtected: Bool
    var onChange: ((URL) -> Void)?
    @StateObject private var loader: FilePreviewLoader
    @State private var infoTarget: FileURLTarget?
    @State private var isChildEditing = false

    init(url: URL, isProtected: Bool, onChange: ((URL) -> Void)? = nil) {
        self.url = url
        self.isProtected = isProtected
        self.onChange = onChange
        self._loader = StateObject(wrappedValue: FilePreviewLoader(url: url))
    }

    var body: some View {
        content
            .donkNavigationTitle(url.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isChildEditing {
                        moreMenu
                    }
                }
            }
            .onPreferenceChange(StorageEditingPreferenceKey.self) { isChildEditing = $0 }
            .sheet(item: $infoTarget) { target in
                FileInfoSheet(url: target.url)
            }
            .task { await loader.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .donkScreenBackground()
        case let .failed(message):
            StorageErrorView(title: "Can't open file", message: message)
                .donkScreenBackground()
        case let .ready(route, kind, size):
            switch route {
            case let .text(json):
                TextFilePreview(url: url, isJSON: json, isEditable: !isProtected, onSave: onChange)
            case .plist:
                PlistFilePreview(url: url, isEditable: !isProtected, onSave: onChange) {
                    loader.fallBack(to: .hex)
                }
            case .image:
                ImageFilePreview(url: url, fileSize: size) {
                    loader.fallBack(to: .hex)
                }
            case .sqlite:
                SQLiteBrowserView(url: url, fileSize: size)
            case .quickLook:
                QuickLookPreview(url: url)
                    .ignoresSafeArea(edges: .bottom)
            case .hex:
                HexFilePreview(url: url, fileSize: size, kind: kind)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { DonkShare.share(fileURL: url) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { DonkPasteboard.copy(url.path, label: "Path") } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            Button { infoTarget = FileURLTarget(url: url) } label: { Label("Info", systemImage: "info.circle") }
            if case let .ready(route, _, _) = loader.state, route != .hex, route != .sqlite {
                Divider()
                Button { loader.fallBack(to: .hex) } label: { Label("View as Hex", systemImage: "number") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More")
        }
    }
}
