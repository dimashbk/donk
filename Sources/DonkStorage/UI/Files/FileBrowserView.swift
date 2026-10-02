import DonkCore
import DonkUI
import SwiftUI

struct FileURLTarget: Identifiable, Hashable {
    let url: URL

    var id: String { url.path }
}

struct FileBrowserView: View {
    let url: URL
    let title: String
    @StateObject private var model: FileBrowserModel
    @State private var pendingDelete: FileItem?
    @State private var infoTarget: FileURLTarget?

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        self._model = StateObject(wrappedValue: FileBrowserModel(url: url))
    }

    var body: some View {
        content
            .donkNavigationTitle(title)
            .searchable(text: $model.query, prompt: "Search in \(title)")
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    addMenu
                    optionsMenu
                }
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: isConfirmingDelete,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                Button("Delete", role: .destructive) { model.delete(item) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(item.isDirectory ? "The folder and everything inside it will be removed. This can't be undone." : "This can't be undone.")
            }
            .sheet(item: $infoTarget) { target in
                FileInfoSheet(url: target.url)
            }
            .onAppear { model.loadIfNeeded() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            if model.totalCount == 0 {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .donkScreenBackground()
            } else {
                list
            }
        case let .failed(message):
            StorageErrorView(title: "Can't open folder", message: message) {
                Task { await model.reload() }
            }
            .donkScreenBackground()
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                header
            }
            if model.items.isEmpty {
                Section {
                    emptyState
                        .frame(minHeight: 300)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(model.items) { item in
                        row(item)
                    }
                }
            }
        }
        .donkListStyle()
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DonkSpacing.s) {
            Text(DonkTextBreaking.breakable(StorageLocations.displayPath(url)))
                .font(DonkFont.codeCaption)
                .foregroundColor(DonkColor.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DonkSpacing.s) {
                    TonePill(text: itemsSummary, tone: .neutral, icon: "doc.on.doc")
                    if let total = model.totalFileSize {
                        TonePill(text: DonkFormat.bytes(total), tone: .info, icon: "internaldrive")
                    }
                    if model.isProtected {
                        TonePill(text: "donk · read-only", tone: .accent, icon: "lock.fill")
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button { DonkPasteboard.copy(url.path, label: "Path") } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
    }

    private var itemsSummary: String {
        let count = model.totalCount
        let base = count == 1 ? "1 item" : "\(DonkFormat.number(count)) items"
        guard model.hiddenCount > 0 else { return base }
        return base + " · \(model.hiddenCount) hidden"
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No matches",
                message: "Nothing in this folder matches “\(model.query)”.",
                tone: .neutral
            )
        } else if model.totalCount > 0 {
            EmptyStateView(
                icon: "eye.slash",
                title: "Only hidden files",
                message: "This folder contains \(model.hiddenCount) hidden item(s).",
                tone: .neutral,
                actionTitle: "Show Hidden Files"
            ) { model.showsHidden = true }
        } else {
            EmptyStateView(
                icon: "folder",
                title: "Empty folder",
                message: model.isProtected ? "donk hasn't stored anything here yet." : "Use + to create a folder or a text file.",
                tone: .info
            )
        }
    }

    private func row(_ item: FileItem) -> some View {
        NavigationLink {
            destination(for: item)
        } label: {
            FileRowView(item: item, folderSize: model.folderSizes[item.path])
        }
        .onAppear { model.requestSize(for: item) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !item.isProtected {
                Button { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                    .tint(DonkColor.error)
                Button { rename(item) } label: { Label("Rename", systemImage: "pencil") }
                    .tint(DonkColor.warning)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button { infoTarget = FileURLTarget(url: item.url) } label: { Label("Info", systemImage: "info.circle") }
                .tint(DonkColor.info)
            if !item.isDirectory {
                Button { DonkShare.share(fileURL: item.url) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                    .tint(DonkColor.accent)
            }
        }
        .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        Button { DonkPasteboard.copy(item.path, label: "Path") } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Button { DonkPasteboard.copy(item.name, label: "Name") } label: { Label("Copy Name", systemImage: "textformat") }
        if !item.isDirectory {
            Button { DonkShare.share(fileURL: item.url) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Button { infoTarget = FileURLTarget(url: item.url) } label: { Label("Info", systemImage: "info.circle") }
        if !item.isProtected {
            Divider()
            Button { rename(item) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func destination(for item: FileItem) -> some View {
        if item.isDirectory {
            FileBrowserView(url: item.url, title: item.name)
        } else {
            FilePreviewView(url: item.url, isProtected: item.isProtected) { changedURL in
                model.fileDidChange(changedURL)
            }
        }
    }

    // MARK: - Toolbar

    private var addMenu: some View {
        Menu {
            Button { createFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Button { createTextFile() } label: { Label("New Text File", systemImage: "doc.badge.plus") }
        } label: {
            Image(systemName: "plus")
                .accessibilityLabel("Add")
        }
        .disabled(model.isProtected || model.state != .loaded)
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: sortField) {
                ForEach(FileSortField.allCases, id: \.self) { field in
                    Label(field.rawValue, systemImage: field.icon).tag(field)
                }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            Toggle(isOn: Binding(get: { model.sort.ascending }, set: { model.sort.ascending = $0 })) {
                Label("Ascending", systemImage: "arrow.up")
            }
            Divider()
            Toggle(isOn: $model.showsHidden) {
                Label("Show Hidden Files", systemImage: "eye")
            }
            Divider()
            Button { DonkPasteboard.copy(url.path, label: "Path") } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            Button { infoTarget = FileURLTarget(url: url) } label: { Label("Folder Info", systemImage: "info.circle") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Options")
        }
    }

    private var sortField: Binding<FileSortField> {
        Binding(
            get: { model.sort.field },
            set: { field in
                guard field != model.sort.field else { return }
                model.sort = FileSort(field: field, ascending: field.defaultAscending)
            }
        )
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let pendingDelete else { return "Delete?" }
        return "Delete “\(pendingDelete.name)”?"
    }

    // MARK: - Actions

    private func rename(_ item: FileItem) {
        StoragePrompt.text(
            title: "Rename",
            text: item.name,
            placeholder: "Name",
            confirmTitle: "Rename",
            selectsBaseName: !item.isDirectory
        ) { name in
            model.rename(item, to: name)
        }
    }

    private func createFolder() {
        StoragePrompt.text(title: "New Folder", text: "New Folder", placeholder: "Folder name", confirmTitle: "Create") { name in
            model.createFolder(named: name)
        }
    }

    private func createTextFile() {
        StoragePrompt.text(
            title: "New Text File",
            text: "untitled.txt",
            placeholder: "File name",
            confirmTitle: "Create",
            selectsBaseName: true
        ) { name in
            model.createTextFile(named: name)
        }
    }
}

// MARK: - Row

struct FileRowView: View {
    let item: FileItem
    let folderSize: Int64?

    var body: some View {
        HStack(spacing: DonkSpacing.m) {
            DonkIconBadge(item.icon, tone: item.tone, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DonkColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isProtected {
                        TonePill(text: "donk", tone: .accent)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(DonkColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DonkSpacing.s)
            sizeLabel
        }
        .padding(.vertical, 2)
        .opacity(item.isHidden ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sizeLabel: some View {
        if let size = item.size ?? folderSize {
            Text(DonkFormat.bytes(size))
                .font(.caption.monospacedDigit())
                .foregroundColor(DonkColor.textSecondary)
                .lineLimit(1)
                .fixedSize()
        } else if item.isDirectory {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 24, height: 16)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let modified = item.modified {
            parts.append(DonkFormat.relative(modified))
        }
        if item.isSymbolicLink {
            parts.append("alias")
        } else if let kind = item.kind, kind != .folder {
            parts.append(kind.title)
        } else if !item.isDirectory {
            let ext = item.url.pathExtension
            parts.append(ext.isEmpty ? "File" : ext.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}
