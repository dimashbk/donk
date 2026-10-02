import DonkJSON
import SwiftUI

// MARK: - Public view

public struct JSONBodyView: View {
    public enum Mode: String, CaseIterable, Hashable, Sendable {
        case tree = "Tree"
        case pretty = "Pretty"
        case raw = "Raw"
    }

    private let source: JSONBodySource
    private let searchQuery: String
    private let externalSearch: CodeSearchState?
    private let layout: DonkLayoutMode
    private let fileName: String
    @StateObject private var model: JSONBodyModel
    @StateObject private var localSearch = CodeSearchState()
    @State private var mode: Mode

    public init(
        data: Data,
        searchQuery: String = "",
        initialMode: Mode = .tree,
        layout: DonkLayoutMode = .scrolling,
        fileName: String = "body"
    ) {
        self.init(source: .data(data), searchQuery: searchQuery, search: nil, initialMode: initialMode, layout: layout, fileName: fileName)
    }

    public init(
        text: String,
        searchQuery: String = "",
        initialMode: Mode = .tree,
        layout: DonkLayoutMode = .scrolling,
        fileName: String = "body"
    ) {
        self.init(source: .text(text), searchQuery: searchQuery, search: nil, initialMode: initialMode, layout: layout, fileName: fileName)
    }

    public init(
        data: Data,
        search: CodeSearchState,
        initialMode: Mode = .tree,
        layout: DonkLayoutMode = .scrolling,
        fileName: String = "body"
    ) {
        self.init(source: .data(data), searchQuery: "", search: search, initialMode: initialMode, layout: layout, fileName: fileName)
    }

    public init(
        text: String,
        search: CodeSearchState,
        initialMode: Mode = .tree,
        layout: DonkLayoutMode = .scrolling,
        fileName: String = "body"
    ) {
        self.init(source: .text(text), searchQuery: "", search: search, initialMode: initialMode, layout: layout, fileName: fileName)
    }

    private init(
        source: JSONBodySource,
        searchQuery: String,
        search: CodeSearchState?,
        initialMode: Mode,
        layout: DonkLayoutMode,
        fileName: String
    ) {
        self.source = source
        self.searchQuery = searchQuery
        self.externalSearch = search
        self.layout = layout
        self.fileName = fileName
        self._model = StateObject(wrappedValue: JSONBodyModel(source: source))
        self._mode = State(initialValue: initialMode)
    }

    private var search: CodeSearchState {
        externalSearch ?? localSearch
    }

    private var horizontalInset: CGFloat {
        layout == .scrolling ? DonkSpacing.l : 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: layout == .scrolling ? .infinity : nil, alignment: .topLeading)
        .onAppear(perform: syncLocalQuery)
        .onChange(of: searchQuery) { _ in syncLocalQuery() }
        .onChange(of: source) { model.load($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 160)
        case .empty:
            EmptyStateView(icon: "doc", title: "Empty body", message: "There is no content to show.", tone: .neutral)
                .frame(minHeight: 220)
        case let .json(value, pretty, raw):
            header(showsModes: true, text: mode == .raw ? raw : pretty, fileExtension: "json")
            switch mode {
            case .tree:
                JSONTreeView(value: value, search: search, layout: layout)
            case .pretty:
                CodeView(text: pretty, language: .json, search: search, layout: layout)
            case .raw:
                CodeView(text: raw, language: .json, search: search, layout: layout)
            }
        case let .text(text):
            header(showsModes: false, text: text, fileExtension: "txt")
            CodeView(text: text, language: .plain, search: search, layout: layout)
        case let .binary(preview, size):
            HStack(spacing: DonkSpacing.s) {
                TonePill(text: "Binary · \(DonkFormat.bytes(size))", tone: .neutral, icon: "cube.box")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalInset)
            .padding(.top, layout == .scrolling ? DonkSpacing.s : 0)
            CodeView(text: preview, language: .plain, search: search, layout: layout)
        }
    }

    private func header(showsModes: Bool, text: String, fileExtension: String) -> some View {
        HStack(spacing: DonkSpacing.s) {
            if showsModes {
                SegmentedTabs(selection: $mode, tabs: Mode.allCases, title: \.rawValue)
                    .frame(maxWidth: 260)
            } else {
                TonePill(text: "Text", tone: .neutral, icon: "text.alignleft")
            }
            Spacer(minLength: DonkSpacing.xs)
            CopyButton(label: "Body") { text }
            Button {
                let name = fileName.contains(".") ? fileName : fileName + "." + fileExtension
                DonkShare.share(fileNamed: name, data: Data(text.utf8))
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share body")
        }
        .tint(DonkColor.accent)
        .padding(.horizontal, horizontalInset)
        .padding(.top, layout == .scrolling ? DonkSpacing.s : 0)
    }

    private func syncLocalQuery() {
        guard externalSearch == nil, localSearch.query != searchQuery else { return }
        localSearch.query = searchQuery
    }
}

// MARK: - Model

enum JSONBodySource: Equatable, Sendable {
    case data(Data)
    case text(String)

    var byteCount: Int {
        switch self {
        case let .data(data): return data.count
        case let .text(text): return text.utf8.count
        }
    }
}

@MainActor
final class JSONBodyModel: ObservableObject {
    enum Content: Sendable {
        case loading
        case empty
        case json(JSONValue, pretty: String, raw: String)
        case text(String)
        case binary(preview: String, size: Int)
    }

    @Published private(set) var content: Content = .loading
    private var generation = 0

    init(source: JSONBodySource) {
        load(source)
    }

    func load(_ source: JSONBodySource) {
        generation += 1
        let current = generation
        if source.byteCount <= 48_000 {
            content = Self.parse(source)
            return
        }
        content = .loading
        Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) {
                JSONBodyModel.parse(source)
            }.value
            guard let self, current == self.generation else { return }
            self.content = parsed
        }
    }

    nonisolated static func parse(_ source: JSONBodySource) -> Content {
        let data: Data
        let text: String?
        switch source {
        case let .data(bytes):
            data = bytes
            text = String(data: bytes, encoding: .utf8)
        case let .text(string):
            data = Data(string.utf8)
            text = string
        }
        guard !data.isEmpty else { return .empty }
        if let value = try? JSONValue.parse(data) {
            return .json(value, pretty: value.prettyPrinted(), raw: text ?? String(decoding: data, as: UTF8.self))
        }
        if let text {
            return .text(text)
        }
        return .binary(preview: CodeSearchEngine.hexDump(data), size: data.count)
    }
}
