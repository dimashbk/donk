import DonkCore
import DonkUI
import SwiftUI

struct FileInfoSheet: View {
    let url: URL
    @State private var info: FileInfo?
    @State private var folderSize: Int64?

    var body: some View {
        DonkNavigationContainer {
            Group {
                if let info {
                    content(info)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .donkScreenBackground()
                }
            }
            .donkNavigationTitle("Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    StorageDoneButton()
                }
            }
        }
        .donkTheme()
        .task { await load() }
    }

    private func content(_ info: FileInfo) -> some View {
        DonkScrollContainer {
            HStack(spacing: DonkSpacing.m) {
                DonkIconBadge(info.kind.icon, tone: info.kind.tone, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DonkTextBreaking.breakable(info.name))
                        .font(DonkFont.headline)
                        .foregroundColor(DonkColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let type = info.typeDescription {
                            TonePill(text: type, tone: .neutral)
                        }
                        if StorageLocations.isProtected(url) {
                            TonePill(text: "donk · read-only", tone: .accent, icon: "lock.fill")
                        }
                    }
                }
            }
            DonkCard(title: "General", icon: "info.circle", tone: .info) {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Path", value: info.url.path, monospacedValue: true, layout: .vertical)
                    Divider()
                    KeyValueRow(key: "Size", value: sizeText(info))
                    if let created = info.created {
                        Divider()
                        KeyValueRow(key: "Created", value: StorageFormat.dateTime(created))
                    }
                    if let modified = info.modified {
                        Divider()
                        KeyValueRow(key: "Modified", value: StorageFormat.dateTime(modified))
                    }
                    Divider()
                    KeyValueRow(key: "Protection", value: info.protection ?? "Unknown")
                    Divider()
                    KeyValueRow(key: "Hidden", value: info.isHidden ? "Yes" : "No")
                    if let excluded = info.isExcludedFromBackup {
                        Divider()
                        KeyValueRow(key: "Backup", value: excluded ? "Excluded" : "Included")
                    }
                    if let destination = info.symlinkDestination {
                        Divider()
                        KeyValueRow(key: "Points to", value: destination, monospacedValue: true, layout: .vertical)
                    }
                }
            } accessory: {
                CopyButton(text: info.url.path, label: "Path")
            }
            HeaderListView(
                info.attributes.map { DonkKeyValue(key: $0.0, value: $0.1) },
                title: "Attributes",
                monospacedValues: true,
                emptyText: "No attributes"
            )
            if !info.isDirectory {
                Button {
                    DonkShare.share(fileURL: url)
                } label: {
                    Label("Share File", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(DonkColor.accent)
            }
        }
    }

    private func sizeText(_ info: FileInfo) -> String {
        if let size = info.size ?? folderSize {
            return DonkFormat.bytes(size) + " (\(DonkFormat.number(Int(size))) bytes)"
        }
        return info.isDirectory ? "Calculating…" : "Unknown"
    }

    private func load() async {
        let url = self.url
        let loaded = await Task.detached(priority: .userInitiated) { FileInfo.load(url) }.value
        info = loaded
        if loaded.isDirectory, loaded.size == nil {
            folderSize = await FolderSizeCache.shared.size(of: url)
        }
    }
}
