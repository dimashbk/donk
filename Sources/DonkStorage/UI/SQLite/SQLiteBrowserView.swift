import DonkCore
import DonkUI
import SwiftUI

// MARK: - Database

@MainActor
final class SQLiteDatabaseModel: ObservableObject {
    let url: URL
    @Published private(set) var reader: SQLiteReader?
    @Published private(set) var tables: [SQLiteTable] = []
    @Published private(set) var state: StorageLoadState = .idle

    init(url: URL) {
        self.url = url
    }

    func load() async {
        state = .loading
        let url = self.url
        let existing = reader
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(SQLiteReader, [SQLiteTable]), Error> in
            Result {
                let reader = try existing ?? SQLiteReader(url: url)
                return (reader, try reader.tables())
            }
        }.value
        switch result {
        case let .success((reader, tables)):
            self.reader = reader
            self.tables = tables
            state = .loaded
        case let .failure(error):
            state = .failed(error.localizedDescription)
        }
    }
}

struct SQLiteBrowserView: View {
    let url: URL
    let fileSize: Int64
    @StateObject private var model: SQLiteDatabaseModel
    @State private var query = ""

    init(url: URL, fileSize: Int64) {
        self.url = url
        self.fileSize = fileSize
        self._model = StateObject(wrappedValue: SQLiteDatabaseModel(url: url))
    }

    var body: some View {
        content
            .searchable(text: $query, prompt: "Filter tables")
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .task {
                if model.state == .idle {
                    await model.load()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            if model.tables.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .donkScreenBackground()
            } else {
                list
            }
        case let .failed(message):
            StorageErrorView(title: "Can't open database", message: message) {
                Task { await model.load() }
            }
            .donkScreenBackground()
        case .loaded:
            list
        }
    }

    private var filteredTables: [SQLiteTable] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return model.tables }
        return model.tables.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var list: some View {
        List {
            Section {
                HStack(spacing: DonkSpacing.s) {
                    TonePill(text: "SQLite", tone: .accent, icon: "cylinder.split.1x2.fill")
                    TonePill(text: DonkFormat.bytes(fileSize), tone: .neutral)
                    TonePill(text: "Read-only", tone: .neutral, icon: "lock.fill")
                    Spacer(minLength: 0)
                }
            }
            if filteredTables.isEmpty {
                Section {
                    EmptyStateView(
                        icon: query.isEmpty ? "tablecells" : "magnifyingglass",
                        title: query.isEmpty ? "No tables" : "No matches",
                        message: query.isEmpty ? "This database has no user tables or views." : "No table matches “\(query)”.",
                        tone: .neutral
                    )
                    .frame(minHeight: 280)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filteredTables) { table in
                        NavigationLink {
                            if let reader = model.reader {
                                SQLiteTableView(reader: reader, table: table)
                            }
                        } label: {
                            DonkLabelRow(
                                icon: table.kind == .view ? "rectangle.on.rectangle" : "tablecells",
                                tone: table.kind == .view ? .grpc : .accent,
                                title: table.name,
                                subtitle: table.kind == .view ? "View" : "Table"
                            ) {
                                Text(table.rowCount.map { DonkFormat.number($0) } ?? "–")
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                        .contextMenu {
                            Button { DonkPasteboard.copy(table.name, label: "Table name") } label: {
                                Label("Copy Name", systemImage: "doc.on.doc")
                            }
                        }
                    }
                } header: {
                    DonkSectionHeader("Tables", icon: "tablecells", count: model.tables.count)
                }
            }
        }
        .donkListStyle()
        .refreshable { await model.load() }
    }
}

// MARK: - Table

@MainActor
final class SQLiteTableModel: ObservableObject {
    let reader: SQLiteReader
    let table: SQLiteTable
    @Published private(set) var columns: [SQLiteColumn] = []
    @Published private(set) var columnNames: [String] = []
    @Published private(set) var rows: [SQLiteRow] = []
    @Published private(set) var totalCount: Int?
    @Published private(set) var state: StorageLoadState = .idle
    @Published private(set) var isLoadingMore = false

    init(reader: SQLiteReader, table: SQLiteTable) {
        self.reader = reader
        self.table = table
        self.totalCount = table.rowCount
    }

    var hasMore: Bool {
        guard let totalCount else { return rows.count % SQLiteReader.pageSize == 0 && !rows.isEmpty }
        return rows.count < totalCount
    }

    func load() async {
        state = .loading
        let reader = self.reader
        let name = table.name
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([SQLiteColumn], [String], [SQLiteRow], Int?), Error> in
            Result {
                let columns = (try? reader.columns(of: name)) ?? []
                let names = columns.isEmpty ? try reader.columnNames(ofQuery: name) : columns.map(\.name)
                let rows = try reader.rows(of: name, limit: SQLiteReader.pageSize, offset: 0)
                return (columns, names, rows, try? reader.rowCount(of: name))
            }
        }.value
        switch result {
        case let .success((columns, names, rows, count)):
            self.columns = columns
            self.columnNames = names
            self.rows = rows
            self.totalCount = count
            state = .loaded
        case let .failure(error):
            state = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let reader = self.reader
        let name = table.name
        let offset = rows.count
        let result = await Task.detached(priority: .userInitiated) {
            Result { try reader.rows(of: name, limit: SQLiteReader.pageSize, offset: offset) }
        }.value
        isLoadingMore = false
        switch result {
        case let .success(page):
            rows += page
            if page.count < SQLiteReader.pageSize {
                totalCount = rows.count
            }
        case let .failure(error):
            DonkToast.show("Couldn't load rows: \(error.localizedDescription)", tone: .error)
        }
    }
}

struct SQLiteTableView: View {
    @StateObject private var model: SQLiteTableModel

    init(reader: SQLiteReader, table: SQLiteTable) {
        self._model = StateObject(wrappedValue: SQLiteTableModel(reader: reader, table: table))
    }

    var body: some View {
        content
            .donkNavigationTitle(model.table.name)
            .task {
                if model.state == .idle {
                    await model.load()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .donkScreenBackground()
        case let .failed(message):
            StorageErrorView(title: "Can't read table", message: message) {
                Task { await model.load() }
            }
            .donkScreenBackground()
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                columnStrip
                    .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            } header: {
                DonkSectionHeader("Columns", icon: "list.bullet.rectangle", count: model.columnNames.count)
            }
            Section {
                if model.rows.isEmpty {
                    EmptyStateView(icon: "tablecells", title: "No rows", message: "This \(model.table.kind.rawValue) is empty.", tone: .neutral)
                        .frame(minHeight: 240)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(model.rows) { row in
                        NavigationLink {
                            SQLiteRowView(table: model.table.name, columns: model.columnNames, row: row)
                        } label: {
                            SQLiteRowCell(columns: model.columnNames, row: row)
                        }
                    }
                    if model.hasMore {
                        Button {
                            Task { await model.loadMore() }
                        } label: {
                            HStack(spacing: DonkSpacing.s) {
                                if model.isLoadingMore {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                Text(loadMoreTitle)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(model.isLoadingMore)
                    }
                }
            } header: {
                DonkSectionHeader("Rows", icon: "tablecells", count: model.totalCount ?? model.rows.count) {
                    Text("\(DonkFormat.number(model.rows.count)) loaded")
                        .font(.caption)
                }
            }
        }
        .donkListStyle()
        .refreshable { await model.load() }
    }

    private var loadMoreTitle: String {
        guard let total = model.totalCount else { return "Load \(SQLiteReader.pageSize) more" }
        let remaining = max(total - model.rows.count, 0)
        return "Load \(min(remaining, SQLiteReader.pageSize)) more · \(DonkFormat.number(remaining)) left"
    }

    private var columnStrip: some View {
        ChipRow {
            if model.columns.isEmpty {
                ForEach(model.columnNames, id: \.self) { name in
                    TonePill(text: name, tone: .neutral)
                }
            } else {
                ForEach(model.columns, id: \.name) { column in
                    HStack(spacing: 4) {
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(DonkColor.warning)
                        }
                        Text(column.name)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(DonkColor.textPrimary)
                        if !column.declaredType.isEmpty {
                            Text(column.declaredType.uppercased())
                                .font(DonkFont.badge)
                                .foregroundColor(DonkColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DonkColor.fill))
                }
            }
        }
    }
}

struct SQLiteRowCell: View {
    let columns: [String]
    let row: SQLiteRow

    var body: some View {
        HStack(alignment: .top, spacing: DonkSpacing.m) {
            Text("\(row.id + 1)")
                .font(DonkFont.badge)
                .foregroundColor(DonkColor.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: DonkRadius.badge, style: .continuous).fill(DonkTone.accent.softBackground))
                .frame(minWidth: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DonkFont.code(.footnote, weight: .semibold))
                    .foregroundColor(DonkColor.textPrimary)
                    .lineLimit(1)
                if !details.isEmpty {
                    Text(details)
                        .font(DonkFont.codeCaption)
                        .foregroundColor(DonkColor.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var pairs: [(String, String)] {
        row.values.enumerated().map { index, value in
            let name = index < columns.count ? columns[index] : "#\(index)"
            return (name, String(value.displayText.prefix(120)).replacingOccurrences(of: "\n", with: " "))
        }
    }

    private var title: String {
        guard let first = pairs.first else { return "Empty row" }
        return first.0 + " = " + first.1
    }

    private var details: String {
        pairs.dropFirst().prefix(6).map { $0.0 + ": " + $0.1 }.joined(separator: " · ")
    }
}

struct SQLiteRowView: View {
    let table: String
    let columns: [String]
    let row: SQLiteRow

    var body: some View {
        DonkScrollContainer {
            DonkCard(title: "Row \(row.id + 1)", icon: "tablecells", tone: .accent) {
                VStack(spacing: 0) {
                    ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                        if index > 0 {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(name(at: index))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(DonkColor.textSecondary)
                                TonePill(text: value.typeName, tone: tone(for: value))
                                Spacer(minLength: 0)
                            }
                            Text(DonkTextBreaking.breakable(String(value.fullText.prefix(8000))))
                                .font(DonkFont.code)
                                .foregroundColor(value == .null ? DonkColor.textTertiary : DonkColor.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button { DonkPasteboard.copy(value.displayText, label: "Value") } label: {
                                Label("Copy Value", systemImage: "doc.on.doc")
                            }
                            Button { DonkPasteboard.copy(name(at: index), label: "Column name") } label: {
                                Label("Copy Column Name", systemImage: "textformat")
                            }
                        }
                    }
                }
            } accessory: {
                CopyButton(label: "Row JSON", title: "JSON") { json }
            }
        }
        .donkNavigationTitle("\(table) · \(row.id + 1)")
    }

    private func name(at index: Int) -> String {
        index < columns.count ? columns[index] : "#\(index)"
    }

    private func tone(for value: SQLiteValue) -> DonkTone {
        switch value {
        case .null: return .neutral
        case .integer, .real: return .info
        case .text: return .web
        case .blob: return .grpc
        }
    }

    private var json: String {
        let members = row.values.enumerated().map { index, value in
            "  " + JSONFormatting.escape(name(at: index)) + ": " + value.jsonFragment
        }
        return "{\n" + members.joined(separator: ",\n") + "\n}"
    }
}
