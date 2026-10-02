# DonkUI — API reference

Design system + windowing infrastructure for donk. iOS 15+, SwiftUI-first. Depends only on `DonkJSON`; never import `DonkCore` here.

```swift
import DonkUI
import DonkJSON   // only when you touch JSONValue directly (DonkCore re-exports it)
```

## Ground rules for consumers

- **Threading.** All views are main-actor. `DonkToast`, `DonkHaptics`, `DonkPasteboard` can be called from **any thread** (they hop to main). `DonkShare`, `DonkWindowManager`, `DonkSceneWindowSet`, `CodeSearchState` and all window classes are `@MainActor`.
- **Layout modes.** Heavy content views take `layout: DonkLayoutMode`:
  - `.scrolling` — the view scrolls itself and fills the space you give it (use for a full tab or screen; required for multi-MB text).
  - `.embedded` — sizes to its content; put it inside your own `ScrollView`/`DonkCard`. Do not embed bodies larger than ~200 KB.
  Defaults: `CodeView` → `.embedded`; `JSONTreeView`, `JSONBodyView`, `CodeEditor` → `.scrolling`.
- **Search.** For find-in-content with "3 of 12" navigation, own a `@StateObject var search = CodeSearchState()`, pass it to `CodeView`/`JSONTreeView`/`JSONBodyView` (`search:` initializers) and show `CodeSearchBar(state:)` or `CodeSearchControls(state:)`, or bind `.searchable(text: $search.query)`. For highlight-only search pass `searchQuery:` instead.
- **Tint.** Apply `.donkTheme()` once at the debugger root so system controls use the Donk accent.
- **Long tokens in `Text`.** SwiftUI auto-hyphenates long unbroken strings (URLs, JWTs, base64), which misrepresents values. Wrap them: `Text(DonkTextBreaking.breakable(url))`. `KeyValueRow`, `JSONTreeView` already do this.
- Screen recipe (Pulse-like detail):

```swift
DonkScrollContainer {
    DonkCard(title: "Request", icon: "arrow.up.circle.fill", tone: .info) {
        KeyValueRow(key: "URL", value: url, monospacedValue: true)
        Divider()
        KeyValueRow(key: "Duration", value: DonkFormat.duration(0.084))
    } accessory: { CopyButton(text: url, label: "URL") }
    HeaderListView(headers.map { ($0.name, $0.value) }, title: "Headers")
}
.donkNavigationTitle("Request")
```

---

## Tokens

### DonkColor
```swift
public enum DonkColor {
    public static let ui: DonkUIColors                       // UIKit twins: DonkColor.ui.accent, .ui.method("GET"), …
    // brand / status (dynamic light/dark)
    public static let accent, success, warning, error, info, grpc, web, neutral, patch: Color
    // surfaces & text (system grouped palette)
    public static let background /* systemGroupedBackground */, card /* secondarySystemGroupedBackground */,
                      elevated /* tertiarySystemGroupedBackground: surface on a card */, fill /* tertiarySystemFill */,
                      separator, textPrimary, textSecondary, textTertiary: Color
    // code
    public static let codeKey, codeString, codeNumber, codeLiteral /* bool/null */, codePunctuation, codeBackground: Color
    public static let searchMatch, searchCurrentMatch: Color
    public static func method(_ method: String) -> Color
}
public struct DonkUIColors: Sendable { /* same names as UIColor */ public func method(_ method: String) -> UIColor }
```
`method(_:)`: GET→info, POST→success, PUT→warning, PATCH→patch, DELETE→error, `UNARY`/`GRPC`/anything containing `STREAM`→grpc, `WS`/`WSS`→web, other→neutral. Case-insensitive.
```swift
Text("Mocked").foregroundColor(DonkColor.warning)
label.textColor = DonkColor.ui.textSecondary
```

### DonkTone
```swift
public enum DonkTone: String, CaseIterable, Hashable, Identifiable, Sendable {
    case success, warning, error, info, neutral, accent, grpc, web
    public var color: Color
    public var uiColor: UIColor
    public var softBackground: Color          // tinted fill (12% light / 20% dark)
    public var softUIBackground: UIColor
    public var defaultIcon: String            // SF Symbol
    public static func httpStatus(_ code: Int) -> DonkTone   // 2xx success, 1xx/3xx info, 4xx warning, 5xx error, else neutral
    public static func grpcStatus(_ code: Int) -> DonkTone   // 0 success, 1 neutral, client-ish codes warning, rest error
}
```
```swift
TonePill(text: "Modified", tone: .warning)
StatusPill(entry.statusLabel, tone: .grpcStatus(code))
```

### DonkFont
```swift
public enum DonkFont {
    public static let largeTitle, title, title3, headline        // rounded
    public static let subheadline, rowTitle, body, callout, footnote, label /* footnote semibold */,
                      caption, captionEmphasized, caption2: Font
    public static let code /* footnote mono */, codeCaption, codeCaption2, badge /* caption2 mono bold */: Font
    public static let metric /* title2 rounded semibold, mono digits */, metricSmall, number: Font
    public static func code(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font
    public static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font
    public static func uiCode(_ style: UIFont.TextStyle = .footnote, weight: UIFont.Weight = .regular) -> UIFont  // Dynamic Type scaled
}
```
Use monospaced fonts only for code, URLs, IDs, numbers.

### DonkSpacing / DonkRadius
```swift
public enum DonkSpacing { xxs 2, xs 4, s 8, m 12, l 16, xl 20, xxl 24, rowVertical 12, screen 16 }   // CGFloat
public enum DonkRadius  { badge 6, small 8, medium 12, card 16, large 22 }
```
Use `RoundedRectangle(cornerRadius: DonkRadius.card, style: .continuous)` for custom surfaces.

---

## Layout & navigation

```swift
public enum DonkLayoutMode: Hashable, Sendable { case scrolling, embedded }

public struct DonkNavigationContainer<Content: View>: View {        // NavigationStack (16+) / NavigationView(.stack)
    public init(@ViewBuilder content: () -> Content)
}
public struct DonkScrollContainer<Content: View>: View {            // ScrollView + VStack(leading) + 16pt padding + grouped background
    public init(spacing: CGFloat = DonkSpacing.l, @ViewBuilder content: () -> Content)
}
public extension View {
    func donkNavigationTitle(_ title: String) -> some View          // navigationTitle + inline display mode
    func donkTheme() -> some View                                   // .tint(DonkColor.accent) — apply at debugger root
    func donkScreenBackground() -> some View                        // DonkColor.background, ignores safe area
    func donkListStyle() -> some View                               // insetGrouped + Donk background
    func donkCardBackground(radius: CGFloat = DonkRadius.card) -> some View
    func donkGlassBackground<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View  // Liquid Glass on iOS 26, ultraThinMaterial before
    func donkFloatingShadow(isVisible: Bool = true) -> some View    // only for floating elements (HUD, bubble, toast)
    func donkInteractive(_ isEnabled: Bool = true, padding: CGFloat = 0) -> some View   // see DonkHostingPassthroughWindow
}
public struct DonkPressableStyle: ButtonStyle { public init(scale: CGFloat = 0.97) }   // .buttonStyle(.donkPressable)
```
```swift
DonkNavigationContainer {
    List { … }.donkListStyle().donkNavigationTitle("Network")
}
.donkTheme()

NavigationLink { NetworkRoot() } label: { ToolTile(icon: "network", title: "Network") }
    .buttonStyle(.donkPressable)
```
Use `NavigationLink(destination:label:)` / `NavigationLink { } label: { }` (no `navigationDestination`, iOS 15).

---

## Components

### DonkCard
```swift
public struct DonkCard<Content: View, Accessory: View>: View {
    public init(title: String? = nil, icon: String? = nil, tone: DonkTone = .accent, padding: CGFloat = DonkSpacing.l,
                @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory)
    public init(title:icon:tone:padding:content:)                    // without accessory
}
```
Card background, continuous radius 16, header row (icon in tone, rounded semibold title, trailing accessory tinted accent). Content is a leading `VStack(spacing: 12)` — use `VStack(spacing: 0)` + `Divider()` yourself for row lists.
```swift
DonkCard(title: "Timing", icon: "clock") { TimingBars(…) } accessory: { CopyButton(text: summary) }
```

### DonkSectionHeader
```swift
public struct DonkSectionHeader<Trailing: View>: View {
    public init(_ title: String, icon: String? = nil, count: Int? = nil, @ViewBuilder trailing: () -> Trailing)
    public init(_ title: String, icon: String? = nil, count: Int? = nil)
}
```
Uppercase footnote-semibold secondary title, optional count capsule, trailing slot. No horizontal padding (add `.padding(.horizontal, 4)` above cards if you want it inset). Works as a `List` section header.
```swift
DonkSectionHeader("Messages", icon: "bubble.left.and.bubble.right", count: messages.count) { Button("Clear") { … } }
```

### DonkIconBadge / DonkLabelRow
```swift
public struct DonkIconBadge: View { public init(_ systemName: String, tone: DonkTone = .accent, size: CGFloat = 32, filled: Bool = false) }
public struct DonkLabelRow<Trailing: View>: View {
    public init(icon: String? = nil, tone: DonkTone = .accent, title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing)
    public init(icon:tone:title:subtitle:)                 // no trailing
    public init(icon:tone:title:subtitle:value: String)    // trailing secondary text
}
```
Settings-style row: tinted rounded-square icon, title + subtitle, trailing slot.
```swift
NavigationLink { … } label: { DonkLabelRow(icon: "key.fill", tone: .warning, title: "Keychain", value: "12") }
```

### MethodBadge / TonePill / StatusPill / CountBadge / LiveDot
```swift
public struct MethodBadge: View { public init(_ method: String) }                     // mono caption2 bold, radius 6, tinted by DonkColor.method
public struct TonePill: View {
    public init(text: String, tone: DonkTone = .neutral, icon: String? = nil)
    public init(_ text: String, tone: DonkTone = .neutral, icon: String? = nil)
}
public struct StatusPill: View {
    public init(_ label: String, tone: DonkTone, isLive: Bool = false)                // live → pulsing dot inside
    public init(code: Int, isLive: Bool = false)                                      // HTTP code; code <= 0 → "…" live neutral
}
public struct CountBadge: View { public init(_ count: Int, tone: DonkTone = .error, filled: Bool = true) }   // compact "1.2K"
public struct LiveDot: View { public init(tone: DonkTone = .info, size: CGFloat = 8, isAnimating: Bool = true) }  // respects Reduce Motion
```
```swift
HStack { MethodBadge(entry.methodLabel); if entry.isModified { TonePill(text: "Modified", tone: .warning, icon: "wand.and.stars") } }
StatusPill(code: response?.statusCode ?? 0)
StatusPill("STREAMING", tone: .grpc, isLive: true)
```

### KeyValueRow / HeaderListView / DonkKeyValue
```swift
public struct DonkKeyValue: Hashable, Sendable {
    public var key: String; public var value: String
    public init(key: String, value: String); public init(_ key: String, _ value: String)
    public static func text(for items: [DonkKeyValue], separator: String = ": ") -> String
}
public enum DonkKeyValueLayout: Hashable, Sendable { case horizontal, vertical }
public struct KeyValueRow: View {
    public static let maskText: String                                     // "••••"
    public init(key: String, value: String, monospacedValue: Bool = false, layout: DonkKeyValueLayout = .horizontal,
                valueTone: DonkTone? = nil, keyWidth: CGFloat? = 112,      // keyWidth: aligned key column (Dynamic Type scaled); nil = natural
                masksValue: Bool = false)                                  // shows •••• until tapped (or Reveal Value in the context menu)
}
public struct HeaderListView: View {
    public init(_ items: [DonkKeyValue], title: String? = nil, monospacedValues: Bool = true, emptyText: String = "No headers",
                embedInCard: Bool = true, keyWidth: CGFloat? = 120, masksKey: ((String) -> Bool)? = nil)
    public init(_ pairs: [(String, String)], title:monospacedValues:emptyText:embedInCard:keyWidth:masksKey:)
}
```
Rows: secondary key that wraps at `-`, `_`, `.`, `/`, `:` (`DonkTextBreaking.breakableKey`), wrapping value (displays up to 4000 chars, copy uses full value), 10pt vertical padding, context menu Copy Value / Copy Key / Copy Key & Value; switches to vertical at accessibility sizes. A masked row shows `••••` with an eye glyph; tap toggles reveal, the context menu adds Reveal/Hide Value, and Copy Value still copies the real value (explicit action). HeaderListView: card with title, count, "copy all" button (`Key: Value` lines, masked rows copied as `••••`), dividers, empty text. `masksKey` decides per key which rows are masked (for example `policy.redactsHeader`). Empty literal is ambiguous → write `HeaderListView([DonkKeyValue](), …)`.
```swift
HeaderListView(request.headers.map { ($0.name, $0.value) }, title: "Request Headers")
KeyValueRow(key: "Status", value: "200 OK", valueTone: .success)
```

### CopyButton / DonkPasteboard
```swift
public struct CopyButton: View {
    public init(text: String, label: String? = nil, title: String? = nil)           // label → toast "<label> copied"; title → visible text
    public init(label: String? = nil, title: String? = nil, value: @escaping () -> String)   // lazy (cURL, big bodies)
}
public enum DonkPasteboard {
    public static let expiration: TimeInterval                                                // 600 s
    public static func copy(_ text: String, label: String? = nil, showsToast: Bool = true)    // any thread; light haptic; toast "Copied"/"cURL copied"
}
```
Writes through `UIPasteboard.general.setItems(_:options:)` with `.localOnly: true` (no Universal Clipboard / Handoff) and `.expirationDate` 10 minutes ahead, so copied tokens and cURL commands do not reach other devices and do not linger.
```swift
CopyButton(label: "cURL", title: "Copy cURL") { CurlExporter.command(for: entry.request) }
.contextMenu { Button("Copy URL") { DonkPasteboard.copy(entry.request.url, label: "URL") } }
```

### FilterChip / ChipRow
```swift
public struct FilterChip: View {
    public init(title: String, icon: String? = nil, isOn: Binding<Bool>, tone: DonkTone = .accent, count: Int? = nil)
    public init(title: String, icon: String? = nil, isSelected: Bool, tone: DonkTone = .accent, count: Int? = nil, action: @escaping () -> Void)
}
public struct ChipRow<Content: View>: View {        // horizontal, no indicators
    public init(spacing: CGFloat = DonkSpacing.s, horizontalPadding: CGFloat = DonkSpacing.l, @ViewBuilder content: () -> Content)
}
```
Selection haptic + spring on toggle. Off: card capsule + hairline; on: tone tint + tone border.
```swift
ChipRow {
    FilterChip(title: "gRPC", icon: "point.3.connected.trianglepath.dotted", isSelected: filter.kinds.contains(.grpc), tone: .grpc, count: grpcCount) { toggle(.grpc) }
}
```

### SegmentedTabs
```swift
public struct SegmentedTabs<Tab: Hashable>: View {
    public init(selection: Binding<Tab>, tabs: [Tab], title: @escaping (Tab) -> String,
                icon: ((Tab) -> String?)? = nil, badge: ((Tab) -> Int?)? = nil)
}
```
Pill track with matched-geometry indicator, selection haptic. ≤4 tabs fill width equally; >4 scroll horizontally and auto-center the selection.
```swift
SegmentedTabs(selection: $tab, tabs: DetailTab.allCases, title: \.rawValue, badge: { $0 == .messages ? count : nil })
```

### EmptyStateView
```swift
public struct EmptyStateView: View {
    public init(icon: String, title: String, message: String? = nil, tone: DonkTone = .accent, actionTitle: String? = nil, action: (() -> Void)? = nil)
}
```
Fills available space, centered tinted circle + symbol, title, message, optional capsule prominent button.
```swift
EmptyStateView(icon: "network.slash", title: "No requests", message: "Requests appear here as they happen.", actionTitle: "Clear Filters") { filter = .init() }
```

### MetricTile / ToolTile
```swift
public struct MetricTile: View {
    public init(title: String, value: String, unit: String? = nil, tone: DonkTone = .accent, icon: String? = nil,
                sparkline: [Double]? = nil, sparklineRange: ClosedRange<Double>? = nil, footnote: String? = nil)
}
public struct ToolTile<Accessory: View>: View {
    public init(icon: String, title: String, subtitle: String? = nil, tone: DonkTone = .accent, badge: Int? = nil, @ViewBuilder accessory: () -> Accessory)
    public init(icon:title:subtitle:tone:badge:)
}
```
Both are card tiles that expand to the height they are offered (min 112 for ToolTile). ToolTile has a fixed rhythm so tiles in a row line up: the icon sits top-left in a 36pt header row, the `badge` and the `accessory` (pill, sparkline) share the trailing slot of that row (the accessory gets layout priority, so a flexible sparkline takes the free width), the title follows at a fixed offset and the subtitle always reserves two lines. In a `LazyVGrid` row heights follow the tallest item only when items are proposed a height; for perfectly equal rows use `HStack { a; b }.fixedSize(horizontal: false, vertical: true)`.
```swift
LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
    NavigationLink { … } label: { ToolTile(icon: "speedometer", title: "Performance", subtitle: "CPU 23%", tone: .success) { DonkPerformance.makeDashboardSparkline().frame(height: 22) } }
        .buttonStyle(.donkPressable)
    MetricTile(title: "Memory", value: "212", unit: "MB", tone: .info, icon: "memorychip", sparkline: samples)
}
```

### SparklineView / LineChartView / DonkChartSeries
```swift
public struct SparklineView: View {
    public init(values: [Double], range: ClosedRange<Double>? = nil, tone: DonkTone = .accent, capacity: Int? = nil,
                lineWidth: CGFloat = 1.6, showsFill: Bool = true, showsLastPoint: Bool = true)
}
public struct DonkChartSeries: Identifiable, Equatable {
    public var id: String; public var name: String; public var values: [Double]; public var tone: DonkTone
    public init(_ name: String, values: [Double], tone: DonkTone = .accent, id: String? = nil)
}
public struct LineChartView: View {
    public init(series: [DonkChartSeries], range: ClosedRange<Double>? = nil, threshold: Double? = nil, unit: String = "",
                window: TimeInterval = 60, capacity: Int? = nil, gridLines: Int = 4, showsLegend: Bool = true,
                valueFormatter: ((Double) -> String)? = nil)
    public init(values: [Double], tone: DonkTone = .accent, name: String = "Value", range:threshold:unit:window:capacity:valueFormatter:)
}
```
Values are evenly spaced samples, oldest first; the newest is at the right edge. `capacity` = number of slots in the window (e.g. 60 for 60 s at 1 Hz) so a filling buffer grows from the right. `range: nil` auto-fits (and includes `threshold`). Smooth monotone curves (no overshoot), gradient fill on the first series, dashed warning threshold, latest-value pill for the first series, x labels `-60s … now`, legend when >1 series. Empty and single-value inputs are handled. Give it a height (`.frame(height: 180)`); minimum 150.
```swift
LineChartView(series: [.init("CPU", values: cpu, tone: .success), .init("Main", values: main, tone: .accent)],
              range: 0...100, threshold: 80, unit: "%", capacity: 60).frame(height: 200)
SparklineView(values: fps, range: 0...60, tone: .accent).frame(height: 28)
```

### DonkSearchField
```swift
public struct DonkSearchField: View { public init(text: Binding<String>, prompt: String = "Search") }
```
Inline field (magnifier, clear button, no autocorrect/capitalization). Prefer `.searchable` for screen-level search; use this for in-content search.

---

## Code & JSON

### CodeLanguage
```swift
public enum CodeLanguage: String, CaseIterable, Hashable, Sendable {
    case plain, json
    public static func detect(contentType: String? = nil, text: String? = nil) -> CodeLanguage   // "json" in content type, or text starting with { / [
}
```

### CodeSearchState / CodeSearchControls / CodeSearchBar
```swift
@MainActor public final class CodeSearchState: ObservableObject {
    @Published public var query: String                                 // resets currentIndex on change
    @Published public private(set) var matchCount: Int
    @Published public private(set) var currentIndex: Int                // 0-based
    @Published public private(set) var isTruncated: Bool                // matches capped (10k code / 2k tree)
    public init(query: String = "")
    public var isActive: Bool; public var hasMatches: Bool
    public var positionLabel: String                                    // "3 of 12", "No matches", ""
    public func next(); public func previous(); public func select(_ index: Int); public func clear()
}
public struct CodeSearchControls: View { public init(state: CodeSearchState) }                // "3 of 12" + ˄ ˅
public struct CodeSearchBar: View { public init(state: CodeSearchState, prompt: String = "Find in body") }   // field + controls
```
Case-insensitive. The attached view reports `matchCount`, highlights all matches (current one stronger) and scrolls to `currentIndex` (in `.embedded` mode `CodeView` scrolls the nearest enclosing scroll view; `JSONTreeView` scrolls only in `.scrolling` mode).
```swift
@StateObject private var search = CodeSearchState()
VStack { CodeSearchBar(state: search); CodeView(text: body, language: .json, search: search, layout: .scrolling) }
```

### CodeView
```swift
public struct CodeView: View {
    public init(text: String, language: CodeLanguage = .plain, searchQuery: String = "", layout: DonkLayoutMode = .embedded)
    public init(text: String, language: CodeLanguage = .plain, search: CodeSearchState, layout: DonkLayoutMode = .embedded)
}
```
Read-only, selectable, monospaced `UITextView` (TextKit 2 on iOS 16+, non-contiguous TextKit 1 on 15). JSON syntax colors: ≤16 KB synchronously, ≤300 KB on a background queue, >300 KB plain (primary color). Transparent background — wrap in a card/`codeBackground` yourself. `.scrolling` has 12/16pt text insets; `.embedded` has none.
```swift
DonkCard(title: "cURL") { CodeView(text: curl) } accessory: { CopyButton(text: curl, label: "cURL") }
CodeView(text: hugeBody, language: .json, layout: .scrolling)
```

### CodeEditor
```swift
public struct CodeEditor: View {
    public init(text: Binding<String>, language: CodeLanguage = .json, layout: DonkLayoutMode = .scrolling,
                showsToolbar: Bool = true, placeholder: String? = nil)
}
```
Editable mono `UITextView`; autocorrect, smart quotes/dashes/insert, spell check and capitalization off. For `.json`: live highlighting (≤64 KB), toolbar with validity pill ("Valid JSON" / "Line 3:14 · expected ',' or '}'" — tap jumps to the error), **Minify** and **Pretty** (DonkJSON), keyboard accessory with `{ } [ ] " : , ⇥` and Done. `.scrolling` fills the space you give it (`.frame(minHeight:)` in forms); `.embedded` grows with content (min 120).
```swift
CodeEditor(text: $draft.body, language: .json, placeholder: "Response body")
Form { Section("Body") { CodeEditor(text: $body).frame(height: 260) } }
```

### JSONTreeView
```swift
public struct JSONTreeView: View {
    public init(value: JSONValue, searchQuery: String = "", layout: DonkLayoutMode = .scrolling, showsToolbar: Bool = true)
    public init(value: JSONValue, search: CodeSearchState, layout: DonkLayoutMode = .scrolling, showsToolbar: Bool = true)
}
```
Flattened visible-row model in a `LazyVStack` (smooth at 5k+ visible nodes; index built off-main above 60k nodes). Disclosure chevrons, indentation guides, typed colors, container counts `{3}` / `[12]` with collapsed previews, first two levels auto-expanded within a row budget, 100 children per container + "Show 100 more" rows, tap long strings to expand them. Toolbar: node count, search controls, expand all / collapse all. Search matches keys and leaf values, expands paths to matches. Row context menu: Copy Value / Copy JSON (pretty for containers), Copy Key Path (`data.items[3].id`, non-identifier keys as `["a b"]`), Copy Key, Expand/Collapse All Children. Transparent background.
```swift
JSONTreeView(value: try JSONValue.parse(data), search: search)
DonkCard { JSONTreeView(value: value, layout: .embedded, showsToolbar: false) }
```

### JSONBodyView
```swift
public struct JSONBodyView: View {
    public enum Mode: String, CaseIterable, Hashable, Sendable { case tree = "Tree", pretty = "Pretty", raw = "Raw" }
    public init(data: Data, searchQuery: String = "", initialMode: Mode = .tree, layout: DonkLayoutMode = .scrolling, fileName: String = "body")
    public init(text: String, searchQuery:initialMode:layout:fileName:)
    public init(data: Data, search: CodeSearchState, initialMode:layout:fileName:)
    public init(text: String, search: CodeSearchState, initialMode:layout:fileName:)
}
```
Parses off-main above 48 KB. JSON → `Tree | Pretty | Raw` switcher + copy + share-as-file (`<fileName>.json`); non-JSON UTF-8 → plain `CodeView`; binary → size pill + hex dump of the first 16 KB; empty → empty state.
```swift
JSONBodyView(data: response.body?.data ?? Data(), search: search, fileName: "response")
```

---

## Feedback

### DonkToast
```swift
public enum DonkToast {
    public static func show(_ message: String, icon: String? = nil, tone: DonkTone = .neutral, duration: TimeInterval = 2)  // any thread
    public static func dismissAll()
}
```
Capsule at the top in its own passthrough window (`DonkWindowLevel.toast`, never key, touches pass through except on the toast). Up to 3 stacked (newest on top); the same message+tone replaces the existing toast with a bounce. Tap or swipe up dismisses. Liquid Glass on iOS 26, `ultraThinMaterial` before. Non-neutral tones get `tone.defaultIcon` when `icon` is nil. Announced to VoiceOver.
```swift
DonkToast.show("Rule saved", tone: .success)
DonkToast.show("Breakpoint hit: Login", icon: "pause.circle.fill", tone: .warning, duration: 3)
```

### DonkHaptics
```swift
public enum DonkHaptics {
    @MainActor public static var isEnabled: Bool
    public static func light(); medium(); rigid(); success(); warning(); error(); selection()   // any thread
}
```
Light on copy/toggle, selection on segment/chip change, success/warning/error for outcomes.

### DonkShare
```swift
@MainActor public enum DonkShare {
    public static func share(text: String)
    public static func share(items: [Any], completion: (() -> Void)? = nil)
    public static func share(fileNamed name: String, data: Data)        // writes tmp/DonkShare/<uuid>/<name> (previous exports removed)
    public static func share(fileURL: URL)
    public static func writeTemporaryFile(named name: String, data: Data) throws -> URL
}
```
Presents `UIActivityViewController` from the top-most controller of the visible debugger window (`DonkKeyWindow`), else the app's key window; iPad popover anchored at the presenter's center. The controller is registered with `DonkWindowManager.markDonkPresentation`.
```swift
DonkShare.share(fileNamed: "donk.har", data: try HARExporter.data(for: entries))
```

### DonkFormat
```swift
public enum DonkFormat {
    public static func bytes(_ count: Int) -> String; bytes(_ count: Int64)      // "512 B", "1.5 KB", "3.2 MB" (1024-based, 1 decimal)
    public static func duration(_ seconds: TimeInterval) -> String              // "0.42 ms", "84 ms", "1.24 s", "12.3 s", "2m 03s", "1h 02m"
    public static func time(_ date: Date) -> String                             // "HH:mm:ss.SSS"
    public static func dateTime(_ date: Date) -> String                         // "yyyy-MM-dd HH:mm:ss"
    public static func relative(_ date: Date, now: Date = Date()) -> String     // "now", "12s ago", "5m ago", "3h ago", "2d ago", "Sep 28"
    public static func percent(_ fraction: Double, fractionDigits: Int = 0) -> String   // 0.423 → "42%" (input is a fraction; 1.4 → "140%")
    public static func number(_ value: Int) -> String                           // "12,345"
    public static func number(_ value: Double, fractionDigits: Int = 1) -> String
    public static func compact(_ value: Int) -> String                          // "999", "1.2K", "12K", "2.5M"
}
```

### DonkTextBreaking
```swift
public enum DonkTextBreaking {
    public static let longRunThreshold: Int                                   // 24
    public static func breakable<S: StringProtocol>(_ text: S) -> String      // inserts zero-width spaces inside runs > 24 chars
    public static let keySeparators: Set<Character>                           // - _ . / :
    public static func breakableKey<S: StringProtocol>(_ text: S) -> String   // breaks after separators; per-character only for separator-free runs > 24
}
```
Display only — never copy/export the returned string.

---

## Windowing (UIKit, all `@MainActor`)

### DonkWindowLevel / DonkWindowMarker
```swift
public enum DonkWindowLevel {
    public static let inspector /* .alert+100 */, hud /* +200 */, bubble /* +300 */, debugger /* +400 */, toast /* +500 */: UIWindow.Level
}
public protocol DonkWindowMarker: AnyObject {}    // adopt on every Donk-owned UIWindow subclass (the classes below already do)
```

### DonkWindowManager
```swift
@MainActor public enum DonkWindowManager {
    public static var windowScenes: [UIWindowScene]                 // connected, foregroundActive first
    public static var activeWindowScene: UIWindowScene?             // per state (foregroundActive, then foregroundInactive): preferred scene, key window's scene, first scene
    public static var preferredScene: UIWindowScene?                // weak; set by the umbrella when a bubble is tapped or the device shaken in a scene
    public static func preferScene(_ scene: UIWindowScene?)
    public static var foregroundWindowScenes: [UIWindowScene]
    public static func isDonkWindow(_ window: UIWindow) -> Bool
    public static var appWindows: [UIWindow]                        // active scene, non-Donk, sorted by level
    public static func appWindows(in scene: UIWindowScene?) -> [UIWindow]
    public static var donkWindows: [UIWindow]
    public static var appKeyWindow: UIWindow?                       // app's key window even while the debugger is key
    public static func appKeyWindow(in scene: UIWindowScene?) -> UIWindow?
    public static var debuggerWindow: DonkKeyWindow?                // visible DonkKeyWindow in the active scene
    public static func debuggerWindow(in scene: UIWindowScene?) -> DonkKeyWindow?
    public static func topViewController(in window: UIWindow?) -> UIViewController?
    public static var presentingViewController: UIViewController?   // debugger top VC if visible, else app's top VC
    public static func refreshSystemAppearance()                    // re-query status bar / home indicator / edge gestures on visible passthrough roots and the app root
    public static func markDonkPresentation(_ controller: UIViewController)        // weak registry of controllers donk presented itself
    public static func isDonkPresentation(_ controller: UIViewController) -> Bool  // registered, or a type whose modules are all Donk*/SwiftUI/UIKit/Swift
    public static func presentationChain(above controller: UIViewController) -> [UIViewController]
    public static func firstForeignPresentation(above controller: UIViewController) -> UIViewController?
    public static var sceneEvents: AnyPublisher<DonkSceneEvent, Never>
    public static func observeScenes(_ handler: @escaping @MainActor (DonkSceneEvent) -> Void) -> AnyCancellable
}
public enum DonkSceneEvent { case connected, activated, deactivated, enteredForeground, enteredBackground, disconnected /* (UIWindowScene) */
    public var scene: UIWindowScene }
```
```swift
let screenshotTarget = DonkWindowManager.appKeyWindow
cancellable = DonkWindowManager.observeScenes { event in if case .activated(let scene) = event { attach(to: scene) } }
```

### DonkSceneWindowSet
```swift
@MainActor public final class DonkSceneWindowSet<Window: UIWindow> {
    public init(_ factory: @escaping @MainActor (UIWindowScene) -> Window)
    public var isActive: Bool                    // true: one visible window per foreground scene, created on connect/activate, dropped on disconnect; false: hide + release all
    public var onWindowCreated: (@MainActor (Window) -> Void)?
    public var windows: [Window]; public var activeWindow: Window?
    public func window(for scene: UIWindowScene) -> Window?
    @discardableResult public func ensureWindow(for scene: UIWindowScene) -> Window
    public func forEach(_ body: (Window) -> Void)
    public func removeAll()
}
```
```swift
let bubbles = DonkSceneWindowSet { scene in DonkHostingPassthroughWindow(windowScene: scene, level: DonkWindowLevel.bubble, rootView: BubbleView()) }
bubbles.isActive = configuration.showsBubble
```

### DonkPassthroughWindow / DonkPassthroughRootViewController
```swift
open class DonkPassthroughWindow: UIWindow, DonkWindowMarker {
    public convenience init(windowScene: UIWindowScene, level: UIWindow.Level, rootViewController: UIViewController? = nil)  // nil → DonkPassthroughRootViewController
    public var capturesAllTouches: Bool                          // true: behaves like a normal window (e.g. inspector picking)
    public var interactionTest: ((CGPoint, UIView) -> Bool)?     // custom accept rule (point in window coords, hit view)
    public var interactiveViews: [UIView]
    public func addInteractiveView(_ view: UIView); public func removeInteractiveView(_ view: UIView)   // weak
    open func shouldReceiveTouch(at point: CGPoint, hitView: UIView) -> Bool
    // canBecomeKey == false; transparent; hitTest returns nil unless one of the rules accepts
}
open class DonkPassthroughRootViewController: UIViewController {   // clear view; mirrors the app's top VC of the same scene
    public func refreshSystemAppearance()
    public static func resolvedStatusBarStyle(_ style: UIStatusBarStyle, interfaceStyle: UIUserInterfaceStyle) -> UIStatusBarStyle
}
```
The root forwards status bar style/hidden, home-indicator auto-hiding, screen-edge gesture deferral and orientations from the app's top controller (fallbacks `.default`/`false`/`[]`/`.all`). A forwarded `.default` is resolved against the app controller's (or app window's) `userInterfaceStyle` into `.lightContent`/`.darkContent`, because UIKit would otherwise resolve it with the donk window's traits and ignore the app window's `overrideUserInterfaceStyle`. The window refreshes these when it becomes visible.

Show with `window.isHidden = false` (never `makeKeyAndVisible`).

### DonkHostingPassthroughWindow
```swift
open class DonkHostingPassthroughWindow<Content: View>: DonkPassthroughWindow {
    public init(windowScene: UIWindowScene, level: UIWindow.Level, rootView: Content)
    public var rootView: Content?              // set to replace the SwiftUI content
    public var hostingView: UIView?
    public var interactiveRegions: [CGRect]    // window coordinates, reported by .donkInteractive()
}
```
SwiftUI content on a transparent hosting controller. **Only regions marked `.donkInteractive()` receive touches**; everything else passes through to the app. Mark the final, positioned element (frames come from layout, so an element moved with `.offset` should be marked before the offset or positioned with `.position`).
```swift
let hud = DonkHostingPassthroughWindow(windowScene: scene, level: DonkWindowLevel.hud, rootView: FPSPill().donkInteractive())
hud.isHidden = false
```

### DonkKeyWindow
```swift
open class DonkKeyWindow: UIWindow, DonkWindowMarker {
    public convenience init(windowScene: UIWindowScene, level: UIWindow.Level = DonkWindowLevel.debugger, rootViewController: UIViewController? = nil)
    public private(set) weak var previousKeyWindow: UIWindow?
    public private(set) var isPresented: Bool
    public var restoresAppKeyWindowWhenIdle: Bool   // default true; false also lets any touch make the window key
    public var isEditingText: Bool                 // a UIKeyInput inside this window is first responder
    open func present()        // remembers the app's key window, ends editing there, shows the window WITHOUT making it key
    open func dismiss()        // ends editing, hides, gives key status back to the remembered app window (fallback: topmost normal-level app window)
    public func restoreAppKeyWindow()
}
```
The window is visible but not key while it is open, so host code that looks up "the key window" (`topMostViewController()`, loaders, push routing) keeps landing on the app window. It becomes key only while one of its text inputs is editing. `canBecomeKey` is true only for a short moment after a touch begins on (or inside) a `UITextField`, an editable `UITextView` or a `UISearchBar` (this covers SwiftUI `TextField`, `TextEditor` and `.searchable`), tracked in `sendEvent`, or while `isEditingText`; ordinary taps on buttons, toggles and lists never make it key. UIKit keys it on such a touch, and the window also calls `makeKey()` on `UITextField`/`UITextView` begin-editing notifications as a fallback for programmatic focus. On end editing, keyboard hide, or any other moment it is key with no text input first responder (checked on the next run loop turn), it hands key status back to the app window.
```swift
let window = DonkKeyWindow(windowScene: scene, rootViewController: UIHostingController(rootView: DebuggerRoot().donkTheme()))
window.present()
```

---

## Gallery

```swift
public struct DonkUIGallery: View { public init(embedInNavigation: Bool = true) }
```
Visual QA of every component with live sample data and a System / Light / Dark switch. Pages: Colors & Type, Badges & Pills, Cards & Rows, Controls, Tiles & Charts, Empty State, Code View (+ ~1 MB body), Code Editor, JSON Tree (+ 5k nodes), Body View (JSON / text / binary / empty), Toasts · Haptics · Share.
