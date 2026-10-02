import SwiftUI

// MARK: - State

@MainActor
public final class CodeSearchState: ObservableObject {
    @Published public var query: String {
        didSet {
            if query != oldValue {
                currentIndex = 0
            }
        }
    }

    @Published public private(set) var matchCount = 0
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var isTruncated = false

    public init(query: String = "") {
        self.query = query
    }

    public var isActive: Bool {
        !query.isEmpty
    }

    public var hasMatches: Bool {
        matchCount > 0
    }

    public var positionLabel: String {
        guard isActive else { return "" }
        guard matchCount > 0 else { return "No matches" }
        return "\(currentIndex + 1) of \(matchCount)\(isTruncated ? "+" : "")"
    }

    public func next() {
        guard matchCount > 0 else { return }
        currentIndex = (currentIndex + 1) % matchCount
    }

    public func previous() {
        guard matchCount > 0 else { return }
        currentIndex = (currentIndex - 1 + matchCount) % matchCount
    }

    public func select(_ index: Int) {
        guard matchCount > 0 else { return }
        currentIndex = min(max(0, index), matchCount - 1)
    }

    public func clear() {
        query = ""
    }

    func report(matchCount count: Int, truncated: Bool) {
        if matchCount != count {
            matchCount = count
        }
        if isTruncated != truncated {
            isTruncated = truncated
        }
        if count == 0 {
            if currentIndex != 0 { currentIndex = 0 }
        } else if currentIndex >= count {
            currentIndex = 0
        }
    }
}

// MARK: - Search field

public struct DonkSearchField: View {
    @Binding private var text: String
    private let prompt: String
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, prompt: String = "Search") {
        self._text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundColor(DonkColor.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(DonkColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DonkColor.fill)
        )
    }
}

// MARK: - Match navigation

public struct CodeSearchControls: View {
    @ObservedObject private var state: CodeSearchState

    public init(state: CodeSearchState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 2) {
            if state.isActive {
                Text(state.positionLabel)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundColor(state.hasMatches ? DonkColor.textSecondary : DonkColor.textTertiary)
                    .lineLimit(1)
                    .padding(.trailing, 4)
            }
            Button {
                DonkHaptics.selection()
                state.previous()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Previous match")
            Button {
                DonkHaptics.selection()
                state.next()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("Next match")
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .tint(DonkColor.accent)
        .disabled(!state.hasMatches)
    }
}

public struct CodeSearchBar: View {
    @ObservedObject private var state: CodeSearchState
    private let prompt: String

    public init(state: CodeSearchState, prompt: String = "Find in body") {
        self.state = state
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: DonkSpacing.s) {
            DonkSearchField(text: $state.query, prompt: prompt)
            if state.isActive {
                CodeSearchControls(state: state)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.isActive)
    }
}
