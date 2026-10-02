import Donk
import DonkUI
import SwiftUI

struct WebViewDemoView: View {
    private enum Tab: String, CaseIterable {
        case playground, site, captured

        var title: String {
            switch self {
            case .playground: return "Playground"
            case .site: return "Real site"
            case .captured: return "Captured"
            }
        }

        var icon: String {
            switch self {
            case .playground: return "hammer"
            case .site: return "globe"
            case .captured: return "list.bullet.rectangle"
            }
        }
    }

    @StateObject private var model = WebViewDemoModel()
    @State private var tab: Tab = .playground

    var body: some View {
        VStack(spacing: 0) {
            SegmentedTabs(
                selection: $tab,
                tabs: Tab.allCases,
                title: { $0.title },
                icon: { $0.icon },
                badge: { $0 == .captured && !model.entries.isEmpty ? model.entries.count : nil }
            )
            .padding(.horizontal, DonkSpacing.l)
            .padding(.vertical, DonkSpacing.s)

            ZStack {
                WebViewHost(webView: model.playground)
                    .opacity(tab == .playground ? 1 : 0)
                    .allowsHitTesting(tab == .playground)
                siteBrowser
                    .opacity(tab == .site ? 1 : 0)
                    .allowsHitTesting(tab == .site)
                WebCapturedListView(model: model)
                    .opacity(tab == .captured ? 1 : 0)
                    .allowsHitTesting(tab == .captured)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab != .captured {
                WebLiveStrip(entries: Array(model.entries.prefix(3)), total: model.entries.count) {
                    tab = .captured
                }
                .padding(.horizontal, DonkSpacing.m)
                .padding(.top, DonkSpacing.s)
                .padding(.bottom, DonkSpacing.xs)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tab)
        .background(DonkColor.background.ignoresSafeArea())
        .navigationTitle("WebView")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        tab = .playground
                        model.runAll()
                    } label: {
                        Label("Run all scenarios", systemImage: "play.fill")
                    }
                    Button {
                        model.reloadPlayground()
                    } label: {
                        Label("Reload playground", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Toggle(isOn: $model.isCapturing) {
                        Label("Capture", systemImage: "record.circle")
                    }
                    Toggle(isOn: $model.isInspectable) {
                        Label("Inspectable in Safari", systemImage: "safari")
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.clear()
                    } label: {
                        Label("Clear captured", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var siteBrowser: some View {
        VStack(spacing: DonkSpacing.s) {
            HStack(spacing: DonkSpacing.s) {
                Menu {
                    ForEach(WebViewDemoModel.Site.allCases) { site in
                        Button {
                            model.open(site)
                        } label: {
                            if site == model.site {
                                Label(site.title, systemImage: "checkmark")
                            } else {
                                Text(site.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.siteIsLoading ? "hourglass" : "lock.fill")
                            .font(DonkFont.caption)
                            .foregroundColor(DonkColor.textSecondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.site.url.host ?? model.site.rawValue)
                                .font(DonkFont.label)
                                .foregroundColor(DonkColor.textPrimary)
                            if !model.siteTitle.isEmpty {
                                Text(model.siteTitle)
                                    .font(DonkFont.caption2)
                                    .foregroundColor(DonkColor.textSecondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(DonkFont.caption)
                            .foregroundColor(DonkColor.textTertiary)
                    }
                    .padding(.horizontal, DonkSpacing.m)
                    .padding(.vertical, DonkSpacing.s)
                    .donkCardBackground(radius: DonkRadius.medium)
                }
                Button {
                    model.reloadSite()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(DonkFont.headline)
                        .frame(width: 40, height: 40)
                        .donkCardBackground(radius: DonkRadius.medium)
                }
                .buttonStyle(.donkPressable)
            }
            .padding(.horizontal, DonkSpacing.m)
            WebViewHost(webView: model.browser)
        }
    }
}
