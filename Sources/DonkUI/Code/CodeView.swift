import SwiftUI
import UIKit

// MARK: - Public view

public struct CodeView: View {
    private let text: String
    private let language: CodeLanguage
    private let searchQuery: String
    private let search: CodeSearchState?
    private let layout: DonkLayoutMode

    public init(text: String, language: CodeLanguage = .plain, searchQuery: String = "", layout: DonkLayoutMode = .embedded) {
        self.text = text
        self.language = language
        self.searchQuery = searchQuery
        self.search = nil
        self.layout = layout
    }

    public init(text: String, language: CodeLanguage = .plain, search: CodeSearchState, layout: DonkLayoutMode = .embedded) {
        self.text = text
        self.language = language
        self.searchQuery = ""
        self.search = search
        self.layout = layout
    }

    public var body: some View {
        if let search {
            CodeViewSearchBridge(text: text, language: language, layout: layout, search: search)
        } else {
            CodeTextView(text: text, language: language, layout: layout, query: searchQuery, currentIndex: nil, onMatches: nil)
        }
    }
}

struct CodeViewSearchBridge: View {
    let text: String
    let language: CodeLanguage
    let layout: DonkLayoutMode
    @ObservedObject var search: CodeSearchState

    var body: some View {
        CodeTextView(
            text: text,
            language: language,
            layout: layout,
            query: search.query,
            currentIndex: search.currentIndex,
            onMatches: { [weak search] count, truncated in
                search?.report(matchCount: count, truncated: truncated)
            }
        )
    }
}

// MARK: - Text view

final class DonkCodeTextView: UITextView {
    var fitsContent = false {
        didSet {
            isScrollEnabled = !fitsContent
            invalidateIntrinsicContentSize()
        }
    }

    private var lastWidth: CGFloat = 0

    static func make(fitsContent: Bool) -> DonkCodeTextView {
        let view: DonkCodeTextView
        if #available(iOS 16, *) {
            view = DonkCodeTextView(usingTextLayoutManager: true)
        } else {
            view = DonkCodeTextView(frame: .zero, textContainer: nil)
            view.layoutManager.allowsNonContiguousLayout = true
        }
        view.fitsContent = fitsContent
        view.backgroundColor = .clear
        view.dataDetectorTypes = []
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = fitsContent ? .zero : UIEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
        view.adjustsFontForContentSizeCategory = false
        view.alwaysBounceVertical = !fitsContent
        view.showsHorizontalScrollIndicator = false
        view.keyboardDismissMode = .interactive
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(fitsContent ? .defaultHigh : .defaultLow, for: .vertical)
        return view
    }

    override var intrinsicContentSize: CGSize {
        guard fitsContent, bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let size = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fitsContent, abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    var enclosingScrollView: UIScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView, !(scrollView is UITextView) {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }

    func scrollToRange(_ range: NSRange, animated: Bool = true) {
        if isScrollEnabled {
            scrollRangeToVisible(range)
        }
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        let rect = firstRect(for: textRange)
        guard !rect.isNull, !rect.isInfinite else { return }
        let scrollView: UIScrollView? = isScrollEnabled ? self : enclosingScrollView
        guard let scrollView else { return }
        let target = scrollView === self ? rect : convert(rect, to: scrollView)
        let inset = scrollView.adjustedContentInset
        let visibleHeight = scrollView.bounds.height - inset.top - inset.bottom
        let minOffset = -inset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        let offset = min(max(target.midY - inset.top - visibleHeight / 2, minOffset), maxOffset)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: animated)
    }
}

// MARK: - Representable

struct CodeTextView: UIViewRepresentable {
    let text: String
    let language: CodeLanguage
    let layout: DonkLayoutMode
    let query: String
    let currentIndex: Int?
    let onMatches: (@MainActor (Int, Bool) -> Void)?

    func makeCoordinator() -> CodeTextCoordinator {
        CodeTextCoordinator()
    }

    func makeUIView(context: Context) -> DonkCodeTextView {
        let view = DonkCodeTextView.make(fitsContent: layout == .embedded)
        view.isEditable = false
        view.isSelectable = true
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: DonkCodeTextView, context: Context) {
        let fitsContent = layout == .embedded
        if view.fitsContent != fitsContent {
            view.fitsContent = fitsContent
        }
        context.coordinator.onMatches = onMatches
        context.coordinator.update(
            text: text,
            language: language,
            query: query,
            currentIndex: currentIndex,
            typeSize: context.environment.dynamicTypeSize
        )
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: DonkCodeTextView, context: Context) -> CGSize? {
        guard layout == .embedded, let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

// MARK: - Coordinator

@MainActor
final class CodeTextCoordinator: NSObject {
    weak var textView: DonkCodeTextView?
    var onMatches: (@MainActor (Int, Bool) -> Void)?

    private var text: String?
    private var language: CodeLanguage = .plain
    private var typeSize: DynamicTypeSize?
    private var query = ""
    private var currentIndex: Int?
    private var matches: [NSRange] = []
    private var appliedMatches: [NSRange] = []
    private var appliedCurrent: NSRange?
    private var contentGeneration = 0
    private var searchGeneration = 0

    func update(text: String, language: CodeLanguage, query: String, currentIndex: Int?, typeSize: DynamicTypeSize) {
        let contentChanged = self.text != text || self.language != language || self.typeSize != typeSize
        if contentChanged {
            self.text = text
            self.language = language
            self.typeSize = typeSize
            loadContent()
        }
        if contentChanged || query != self.query {
            self.query = query
            self.currentIndex = currentIndex
            runSearch()
        } else if currentIndex != self.currentIndex {
            self.currentIndex = currentIndex
            applyCurrentMatch(scroll: true)
        }
    }

    private func loadContent() {
        guard let textView, let text else { return }
        contentGeneration += 1
        let generation = contentGeneration
        matches = []
        appliedMatches = []
        appliedCurrent = nil
        let font = DonkFont.uiCode()
        let length = text.utf16.count
        let highlight = language == .json && length <= JSONSyntax.highlightLimit
        let attributed = JSONSyntax.attributedString(text, language: highlight ? language : .plain, font: font)
        if highlight && length <= JSONSyntax.synchronousLimit {
            JSONSyntax.apply(JSONSyntax.tokens(in: text), to: attributed)
            textView.attributedText = attributed
        } else {
            textView.attributedText = attributed
            if highlight {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let tokens = JSONSyntax.tokens(in: text)
                    DispatchQueue.main.async {
                        self?.applyTokens(tokens, generation: generation)
                    }
                }
            }
        }
        textView.invalidateIntrinsicContentSize()
    }

    private func applyTokens(_ tokens: [JSONSyntax.Token], generation: Int) {
        guard generation == contentGeneration, let textView else { return }
        let storage = textView.textStorage
        storage.beginEditing()
        JSONSyntax.apply(tokens, to: storage)
        storage.endEditing()
    }

    private func runSearch() {
        searchGeneration += 1
        let generation = searchGeneration
        clearMatches()
        guard !query.isEmpty, let text, !text.isEmpty else {
            report(count: 0, truncated: false)
            return
        }
        let query = self.query
        if text.utf16.count <= 200_000 {
            let result = CodeSearchEngine.matches(of: query, in: text)
            applyMatches(result.ranges, truncated: result.truncated, generation: generation)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = CodeSearchEngine.matches(of: query, in: text)
                DispatchQueue.main.async {
                    self?.applyMatches(result.ranges, truncated: result.truncated, generation: generation)
                }
            }
        }
    }

    private func applyMatches(_ ranges: [NSRange], truncated: Bool, generation: Int) {
        guard generation == searchGeneration, let textView else { return }
        matches = ranges
        let storage = textView.textStorage
        let length = storage.length
        if !ranges.isEmpty {
            storage.beginEditing()
            for range in ranges where NSMaxRange(range) <= length {
                storage.addAttribute(.backgroundColor, value: DonkPalette.searchMatch, range: range)
            }
            storage.endEditing()
        }
        appliedMatches = ranges
        report(count: ranges.count, truncated: truncated)
        applyCurrentMatch(scroll: true)
    }

    private func applyCurrentMatch(scroll: Bool) {
        guard let textView else { return }
        let storage = textView.textStorage
        if let previous = appliedCurrent, NSMaxRange(previous) <= storage.length {
            storage.addAttribute(.backgroundColor, value: DonkPalette.searchMatch, range: previous)
        }
        appliedCurrent = nil
        guard let index = currentIndex, matches.indices.contains(index) else { return }
        let range = matches[index]
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.backgroundColor, value: DonkPalette.searchCurrent, range: range)
        appliedCurrent = range
        guard scroll else { return }
        DispatchQueue.main.async { [weak textView] in
            textView?.scrollToRange(range)
        }
    }

    private func clearMatches() {
        defer {
            matches = []
            appliedMatches = []
            appliedCurrent = nil
        }
        guard let textView, !appliedMatches.isEmpty else { return }
        let storage = textView.textStorage
        let length = storage.length
        storage.beginEditing()
        for range in appliedMatches where NSMaxRange(range) <= length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        storage.endEditing()
    }

    private func report(count: Int, truncated: Bool) {
        guard let onMatches else { return }
        DispatchQueue.main.async {
            onMatches(count, truncated)
        }
    }
}
