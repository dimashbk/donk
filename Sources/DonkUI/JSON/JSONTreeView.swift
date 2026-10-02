import DonkJSON
import SwiftUI

// MARK: - Public view

public struct JSONTreeView: View {
    private let value: JSONValue
    private let searchQuery: String
    private let externalSearch: CodeSearchState?
    private let layout: DonkLayoutMode
    private let showsToolbar: Bool
    @StateObject private var model: JSONTreeModel
    @StateObject private var localSearch = CodeSearchState()

    public init(value: JSONValue, searchQuery: String = "", layout: DonkLayoutMode = .scrolling, showsToolbar: Bool = true) {
        self.value = value
        self.searchQuery = searchQuery
        self.externalSearch = nil
        self.layout = layout
        self.showsToolbar = showsToolbar
        self._model = StateObject(wrappedValue: JSONTreeModel(value: value))
    }

    public init(value: JSONValue, search: CodeSearchState, layout: DonkLayoutMode = .scrolling, showsToolbar: Bool = true) {
        self.value = value
        self.searchQuery = ""
        self.externalSearch = search
        self.layout = layout
        self.showsToolbar = showsToolbar
        self._model = StateObject(wrappedValue: JSONTreeModel(value: value))
    }

    public var body: some View {
        JSONTreeContent(
            model: model,
            search: externalSearch ?? localSearch,
            layout: layout,
            showsToolbar: showsToolbar
        )
        .onAppear(perform: syncLocalQuery)
        .onChange(of: searchQuery) { _ in syncLocalQuery() }
        .onChange(of: value) { newValue in model.load(newValue) }
    }

    private func syncLocalQuery() {
        guard externalSearch == nil, localSearch.query != searchQuery else { return }
        localSearch.query = searchQuery
    }
}

// MARK: - Content

struct JSONTreeContent: View {
    @ObservedObject var model: JSONTreeModel
    @ObservedObject var search: CodeSearchState
    let layout: DonkLayoutMode
    let showsToolbar: Bool

    private var leading: CGFloat {
        layout == .scrolling ? DonkSpacing.l : 0
    }

    private var currentRowID: Int? {
        guard search.isActive, model.matchRowIDs.indices.contains(search.currentIndex) else { return nil }
        return model.matchRowIDs[search.currentIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsToolbar {
                toolbar
                Divider()
                    .padding(.leading, leading)
            }
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if layout == .scrolling {
                ScrollViewReader { proxy in
                    ScrollView {
                        rowsStack
                            .padding(.vertical, DonkSpacing.s)
                    }
                    .onChange(of: search.currentIndex) { _ in scrollToCurrent(proxy) }
                    .onChange(of: model.matchRowIDs) { _ in scrollToCurrent(proxy) }
                }
            } else {
                rowsStack
                    .padding(.vertical, DonkSpacing.xs)
            }
        }
        .onAppear {
            model.setQuery(search.query)
            search.report(matchCount: model.matchRowIDs.count, truncated: model.isTruncated)
        }
        .onChange(of: search.query) { model.setQuery($0) }
        .onChange(of: model.matchRowIDs) { ids in
            search.report(matchCount: ids.count, truncated: model.isTruncated)
        }
    }

    private var toolbar: some View {
        HStack(spacing: DonkSpacing.s) {
            Text("\(DonkFormat.number(model.nodeCount)) \(model.nodeCount == 1 ? "node" : "nodes")")
                .font(.caption.weight(.medium))
                .foregroundColor(DonkColor.textTertiary)
                .lineLimit(1)
            Spacer(minLength: DonkSpacing.xs)
            if search.isActive {
                CodeSearchControls(state: search)
            }
            Button {
                DonkHaptics.light()
                model.expandAll()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Expand all")
            Button {
                DonkHaptics.light()
                model.collapseAll()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Collapse all")
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .tint(DonkColor.accent)
        .padding(.leading, leading)
        .padding(.trailing, layout == .scrolling ? DonkSpacing.s : 0)
        .padding(.vertical, 2)
    }

    private var rowsStack: some View {
        let current = currentRowID
        let query = model.activeQuery
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                JSONTreeRowView(row: row, query: query, isCurrent: row.id == current, leading: leading, model: model)
                    .equatable()
                    .id(row.id)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let id = currentRowID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

// MARK: - Row

struct JSONTreeRowView: View, Equatable {
    let row: JSONTreeRow
    let query: String
    let isCurrent: Bool
    let leading: CGFloat
    let model: JSONTreeModel

    @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 17

    static let indent: CGFloat = 14

    nonisolated static func == (lhs: JSONTreeRowView, rhs: JSONTreeRowView) -> Bool {
        lhs.row == rhs.row && lhs.query == rhs.query && lhs.isCurrent == rhs.isCurrent && lhs.leading == rhs.leading
    }

    var body: some View {
        switch row.kind {
        case let .more(remaining):
            moreRow(remaining: remaining)
        case .node:
            nodeRow
        }
    }

    private var indentation: CGFloat {
        leading + CGFloat(row.depth) * Self.indent
    }

    private var guides: some View {
        JSONIndentGuides(depth: row.depth, indent: Self.indent, leading: leading)
            .stroke(DonkColor.separator.opacity(0.75), lineWidth: 1)
    }

    private var nodeRow: some View {
        HStack(alignment: .top, spacing: 6) {
            disclosure
            label
                .font(DonkFont.code)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.leading, indentation)
        .padding(.trailing, DonkSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) { guides }
        .background(isCurrent ? DonkColor.searchCurrentMatch.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.toggle(row)
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isExpandable ? .isButton : [])
        .accessibilityValue(row.childCount > 0 ? (row.isExpanded ? "Expanded" : "Collapsed") : "")
    }

    private var disclosure: some View {
        ZStack {
            if row.childCount > 0 {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DonkColor.textSecondary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            } else {
                Circle()
                    .fill(DonkColor.textTertiary.opacity(0.6))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 12, height: lineHeight)
        .accessibilityHidden(true)
    }

    private var label: Text {
        var result = Text("")
        if let key = row.key {
            let keyColor = row.isIndexKey ? DonkColor.textTertiary : DonkColor.codeKey
            result = JSONTreeHighlighter.text(key, query: row.isIndexKey ? "" : query, color: keyColor, isCurrent: isCurrent)
                + Text(": ").foregroundColor(DonkColor.codePunctuation)
        }
        switch row.valueKind {
        case .object, .array:
            result = result + Text(row.text).foregroundColor(DonkColor.textSecondary)
            if let preview = row.preview {
                result = result + Text("  " + preview)
                    .font(DonkFont.codeCaption)
                    .foregroundColor(DonkColor.textTertiary)
            }
        case .string:
            result = result + JSONTreeHighlighter.text(row.text, query: query, color: DonkColor.codeString, isCurrent: isCurrent)
        case .number:
            result = result + JSONTreeHighlighter.text(row.text, query: query, color: DonkColor.codeNumber, isCurrent: isCurrent)
        case .bool, .null:
            result = result + JSONTreeHighlighter.text(row.text, query: query, color: DonkColor.codeLiteral, isCurrent: isCurrent)
        }
        return result
    }

    @ViewBuilder
    private var menu: some View {
        let isContainer = row.valueKind == .object || row.valueKind == .array
        Button {
            model.copyValue(row)
        } label: {
            Label(isContainer ? "Copy JSON" : "Copy Value", systemImage: "doc.on.doc")
        }
        Button {
            model.copyKeyPath(row)
        } label: {
            Label("Copy Key Path", systemImage: "arrow.triangle.branch")
        }
        if row.key != nil && !row.isIndexKey {
            Button {
                model.copyKey(row)
            } label: {
                Label("Copy Key", systemImage: "key")
            }
        }
        if row.childCount > 0 {
            Divider()
            Button {
                model.expandSubtree(row)
            } label: {
                Label("Expand All Children", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                model.collapseSubtree(row)
            } label: {
                Label("Collapse All Children", systemImage: "arrow.down.right.and.arrow.up.left")
            }
        }
    }

    private func moreRow(remaining: Int) -> some View {
        Button {
            DonkHaptics.light()
            model.showMore(row.node)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                Text("Show \(min(remaining, JSONTreeModel.pageSize)) more")
                    .font(.footnote.weight(.semibold))
                Text("· \(DonkFormat.number(remaining)) hidden")
                    .font(.caption)
                    .foregroundColor(DonkColor.textTertiary)
            }
            .foregroundColor(DonkColor.accent)
            .padding(.vertical, 7)
            .padding(.leading, indentation + 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: .leading) { guides }
    }
}

// MARK: - Helpers

struct JSONIndentGuides: Shape {
    let depth: Int
    let indent: CGFloat
    let leading: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard depth > 0 else { return path }
        for level in 0..<depth {
            let x = (leading + CGFloat(level) * indent + 6).rounded() + 0.5
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}

enum JSONTreeHighlighter {
    static func text(_ string: String, query: String, color: Color, isCurrent: Bool) -> Text {
        guard !query.isEmpty, string.range(of: query, options: .caseInsensitive) != nil else {
            return Text(DonkTextBreaking.breakable(string)).foregroundColor(color)
        }
        let highlight = isCurrent ? DonkColor.searchCurrentMatch : DonkColor.searchMatch
        var attributed = AttributedString()
        var cursor = string.startIndex
        while cursor < string.endIndex,
              let range = string.range(of: query, options: .caseInsensitive, range: cursor..<string.endIndex),
              !range.isEmpty {
            if cursor < range.lowerBound {
                attributed.append(AttributedString(DonkTextBreaking.breakable(string[cursor..<range.lowerBound])))
            }
            var match = AttributedString(DonkTextBreaking.breakable(string[range]))
            match.backgroundColor = highlight
            attributed.append(match)
            cursor = range.upperBound
        }
        if cursor < string.endIndex {
            attributed.append(AttributedString(DonkTextBreaking.breakable(string[cursor...])))
        }
        attributed.foregroundColor = color
        return Text(attributed)
    }
}
