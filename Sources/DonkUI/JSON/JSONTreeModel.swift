import DonkJSON
import SwiftUI

// MARK: - Index

struct JSONTreeIndex: Sendable {
    enum Key: Hashable, Sendable {
        case root
        case member(String)
        case index(Int)
    }

    struct Node: Sendable {
        let key: Key
        let value: JSONValue
        let parent: Int
        let depth: Int
        let position: Int
        var childStart: Int
        var childCount: Int
    }

    let nodes: [Node]
    let containers: [Int]

    init?(value: JSONValue, budget: Int? = nil) {
        var nodes = [Node(key: .root, value: value, parent: -1, depth: -1, position: 0, childStart: 0, childCount: 0)]
        var containers: [Int] = []
        var cursor = 0
        while cursor < nodes.count {
            let node = nodes[cursor]
            let start = nodes.count
            switch node.value {
            case let .object(members):
                if let budget, start + members.count > budget { return nil }
                for (position, member) in members.enumerated() {
                    nodes.append(Node(key: .member(member.key), value: member.value, parent: cursor, depth: node.depth + 1, position: position, childStart: 0, childCount: 0))
                }
                if !members.isEmpty { containers.append(cursor) }
            case let .array(values):
                if let budget, start + values.count > budget { return nil }
                for (position, element) in values.enumerated() {
                    nodes.append(Node(key: .index(position), value: element, parent: cursor, depth: node.depth + 1, position: position, childStart: 0, childCount: 0))
                }
                if !values.isEmpty { containers.append(cursor) }
            default:
                break
            }
            nodes[cursor].childStart = start
            nodes[cursor].childCount = nodes.count - start
            cursor += 1
        }
        self.nodes = nodes
        self.containers = containers
    }

    var displayedNodeCount: Int {
        nodes[0].childCount > 0 ? nodes.count - 1 : 1
    }

    func keyPath(of node: Int) -> String {
        var keys: [Key] = []
        var current = node
        while current > 0 {
            keys.append(nodes[current].key)
            current = nodes[current].parent
        }
        var path = ""
        for key in keys.reversed() {
            switch key {
            case .root:
                break
            case let .member(name):
                if Self.isIdentifier(name) {
                    path += path.isEmpty ? name : "." + name
                } else {
                    path += "[" + JSONFormatting.escape(name) + "]"
                }
            case let .index(position):
                path += "[\(position)]"
            }
        }
        return path.isEmpty ? "$" : path
    }

    func subtreeContainers(of node: Int) -> [Int] {
        var result: [Int] = []
        var stack = [node]
        while let current = stack.popLast() {
            let item = nodes[current]
            guard item.childCount > 0 else { continue }
            result.append(current)
            stack.append(contentsOf: item.childStart..<(item.childStart + item.childCount))
        }
        return result
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
        let tail = head.union(.decimalDigits)
        guard first.isASCII, head.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && tail.contains($0) }
    }
}

// MARK: - Row

struct JSONTreeRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case node
        case more(remaining: Int)
    }

    enum ValueKind: Equatable {
        case object
        case array
        case string
        case number
        case bool
        case null
    }

    let id: Int
    let node: Int
    let kind: Kind
    let depth: Int
    let key: String?
    let isIndexKey: Bool
    let valueKind: ValueKind
    let text: String
    let preview: String?
    let childCount: Int
    let isExpanded: Bool
    let isExpandable: Bool
    let isMatch: Bool
}

// MARK: - Model

@MainActor
final class JSONTreeModel: ObservableObject {
    @Published private(set) var rows: [JSONTreeRow] = []
    @Published private(set) var matchRowIDs: [Int] = []
    @Published private(set) var isLoading = false
    @Published private(set) var nodeCount = 0
    @Published private(set) var activeQuery = ""
    @Published private(set) var isTruncated = false

    static let pageSize = 100
    static let syncBudget = 60_000
    static let autoExpandRowBudget = 600
    nonisolated static let matchLimit = 2_000

    private var index: JSONTreeIndex?
    private var expanded: Set<Int> = []
    private var expandedLeaves: Set<Int> = []
    private var limits: [Int: Int] = [:]
    private var matches: Set<Int> = []
    private var query = ""
    private var loadGeneration = 0
    private var searchGeneration = 0

    init(value: JSONValue) {
        load(value)
    }

    func load(_ value: JSONValue) {
        loadGeneration += 1
        let generation = loadGeneration
        index = nil
        expanded = []
        expandedLeaves = []
        limits = [:]
        matches = []
        if let built = JSONTreeIndex(value: value, budget: Self.syncBudget) {
            install(built)
            return
        }
        isLoading = true
        rows = []
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                JSONTreeIndex(value: value)
            }.value
            guard let self, let built, generation == self.loadGeneration else { return }
            self.install(built)
        }
    }

    private func install(_ built: JSONTreeIndex) {
        index = built
        nodeCount = built.displayedNodeCount
        isLoading = false
        expanded = autoExpansion(built)
        let pending = query
        query = ""
        if pending.isEmpty {
            rebuild()
        } else {
            setQuery(pending)
        }
    }

    // MARK: - Expansion

    func toggle(_ row: JSONTreeRow) {
        guard case .node = row.kind, row.isExpandable else { return }
        if row.childCount > 0 {
            if expanded.contains(row.node) {
                expanded.remove(row.node)
            } else {
                expanded.insert(row.node)
            }
        } else if expandedLeaves.contains(row.node) {
            expandedLeaves.remove(row.node)
        } else {
            expandedLeaves.insert(row.node)
        }
        DonkHaptics.selection()
        if row.childCount <= 50 {
            withAnimation(.easeInOut(duration: 0.18)) { rebuild() }
        } else {
            rebuild()
        }
    }

    func showMore(_ parent: Int) {
        limits[parent] = limit(for: parent) + Self.pageSize
        rebuild()
    }

    func expandAll() {
        guard let index else { return }
        expanded = Set(index.containers.filter { $0 != 0 })
        rebuild()
    }

    func collapseAll() {
        expanded = []
        expandedLeaves = []
        rebuild()
    }

    func expandSubtree(_ row: JSONTreeRow) {
        guard let index else { return }
        expanded.formUnion(index.subtreeContainers(of: row.node).filter { $0 != 0 })
        rebuild()
    }

    func collapseSubtree(_ row: JSONTreeRow) {
        guard let index else { return }
        expanded.subtract(index.subtreeContainers(of: row.node))
        rebuild()
    }

    private func limit(for parent: Int) -> Int {
        limits[parent] ?? Self.pageSize
    }

    private func autoExpansion(_ index: JSONTreeIndex) -> Set<Int> {
        var result: Set<Int> = []
        let root = index.nodes[0]
        var budget = Self.autoExpandRowBudget - min(root.childCount, Self.pageSize)
        var frontier = Array(root.childStart..<(root.childStart + min(root.childCount, Self.pageSize)))
        for _ in 0..<2 {
            var next: [Int] = []
            for node in frontier {
                let item = index.nodes[node]
                guard item.childCount > 0 else { continue }
                let cost = min(item.childCount, Self.pageSize)
                guard cost <= budget else { continue }
                budget -= cost
                result.insert(node)
                next.append(contentsOf: item.childStart..<(item.childStart + cost))
            }
            frontier = next
        }
        return result
    }

    // MARK: - Search

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        searchGeneration += 1
        let generation = searchGeneration
        guard let index, !newQuery.isEmpty else {
            matches = []
            activeQuery = ""
            isTruncated = false
            rebuild()
            return
        }
        if index.nodes.count <= 5_000 {
            let result = Self.search(newQuery, in: index)
            applySearch(result.matches, truncated: result.truncated, query: newQuery)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, generation == self.searchGeneration else { return }
            let result = await Task.detached(priority: .userInitiated) {
                JSONTreeModel.search(newQuery, in: index)
            }.value
            guard generation == self.searchGeneration else { return }
            self.applySearch(result.matches, truncated: result.truncated, query: newQuery)
        }
    }

    private func applySearch(_ found: [Int], truncated: Bool, query: String) {
        guard let index else { return }
        matches = Set(found)
        activeQuery = query
        isTruncated = truncated
        for node in found {
            var child = node
            var parent = index.nodes[node].parent
            while parent >= 0 {
                if parent > 0 {
                    expanded.insert(parent)
                }
                let needed = (index.nodes[child].position / Self.pageSize + 1) * Self.pageSize
                if limit(for: parent) < needed {
                    limits[parent] = needed
                }
                child = parent
                parent = index.nodes[parent].parent
            }
        }
        rebuild()
    }

    nonisolated static func search(_ query: String, in index: JSONTreeIndex) -> (matches: [Int], truncated: Bool) {
        var result: [Int] = []
        let start = index.nodes[0].childCount > 0 ? 1 : 0
        guard start < index.nodes.count else { return ([], false) }
        for position in start..<index.nodes.count {
            let node = index.nodes[position]
            var hit = false
            if case let .member(key) = node.key, key.range(of: query, options: .caseInsensitive) != nil {
                hit = true
            }
            if !hit {
                switch node.value {
                case let .string(string): hit = string.range(of: query, options: .caseInsensitive) != nil
                case let .number(literal): hit = literal.range(of: query, options: .caseInsensitive) != nil
                case let .bool(flag): hit = (flag ? "true" : "false").range(of: query, options: .caseInsensitive) != nil
                case .null: hit = "null".range(of: query, options: .caseInsensitive) != nil
                case .object, .array: break
                }
            }
            guard hit else { continue }
            if result.count >= matchLimit {
                return (result, true)
            }
            result.append(position)
        }
        return (result, false)
    }

    // MARK: - Copy

    func copyValue(_ row: JSONTreeRow) {
        guard let index else { return }
        let value = index.nodes[row.node].value
        switch value {
        case .object, .array: DonkPasteboard.copy(value.prettyPrinted(), label: "JSON")
        case let .string(string): DonkPasteboard.copy(string, label: "Value")
        case let .number(literal): DonkPasteboard.copy(literal, label: "Value")
        case let .bool(flag): DonkPasteboard.copy(flag ? "true" : "false", label: "Value")
        case .null: DonkPasteboard.copy("null", label: "Value")
        }
    }

    func copyKeyPath(_ row: JSONTreeRow) {
        guard let index else { return }
        DonkPasteboard.copy(index.keyPath(of: row.node), label: "Key path")
    }

    func copyKey(_ row: JSONTreeRow) {
        guard let index, case let .member(key) = index.nodes[row.node].key else { return }
        DonkPasteboard.copy(key, label: "Key")
    }

    // MARK: - Rows

    private enum StackItem {
        case node(Int)
        case more(parent: Int, remaining: Int)
    }

    private func rebuild() {
        guard let index else {
            rows = []
            matchRowIDs = []
            return
        }
        var result: [JSONTreeRow] = []
        let root = index.nodes[0]
        if root.childCount == 0 {
            result.append(makeRow(0, in: index))
        } else {
            var stack: [StackItem] = []
            pushChildren(of: 0, in: index, onto: &stack)
            while let item = stack.popLast() {
                switch item {
                case let .node(node):
                    result.append(makeRow(node, in: index))
                    if index.nodes[node].childCount > 0, expanded.contains(node) {
                        pushChildren(of: node, in: index, onto: &stack)
                    }
                case let .more(parent, remaining):
                    result.append(makeMoreRow(parent: parent, remaining: remaining, in: index))
                }
            }
        }
        rows = result
        let ids = result.compactMap { $0.isMatch ? $0.id : nil }
        if ids != matchRowIDs {
            matchRowIDs = ids
        }
    }

    private func pushChildren(of parent: Int, in index: JSONTreeIndex, onto stack: inout [StackItem]) {
        let node = index.nodes[parent]
        let visible = min(node.childCount, limit(for: parent))
        if node.childCount > visible {
            stack.append(.more(parent: parent, remaining: node.childCount - visible))
        }
        var child = node.childStart + visible - 1
        while child >= node.childStart {
            stack.append(.node(child))
            child -= 1
        }
    }

    private func makeMoreRow(parent: Int, remaining: Int, in index: JSONTreeIndex) -> JSONTreeRow {
        JSONTreeRow(
            id: index.nodes.count + parent,
            node: parent,
            kind: .more(remaining: remaining),
            depth: max(0, index.nodes[parent].depth + 1),
            key: nil,
            isIndexKey: false,
            valueKind: .null,
            text: "",
            preview: nil,
            childCount: 0,
            isExpanded: false,
            isExpandable: false,
            isMatch: false
        )
    }

    private func makeRow(_ nodeIndex: Int, in index: JSONTreeIndex) -> JSONTreeRow {
        let node = index.nodes[nodeIndex]
        let key: String?
        let isIndexKey: Bool
        switch node.key {
        case .root:
            key = nil
            isIndexKey = false
        case let .member(name):
            key = name
            isIndexKey = false
        case let .index(position):
            key = "[\(position)]"
            isIndexKey = true
        }
        let isExpanded = expanded.contains(nodeIndex)
        let valueKind: JSONTreeRow.ValueKind
        let text: String
        var preview: String?
        var isExpandable = false
        switch node.value {
        case let .object(members):
            valueKind = .object
            text = members.isEmpty ? "{}" : "{\(members.count)}"
            isExpandable = !members.isEmpty
            if !isExpanded && !members.isEmpty {
                preview = Self.objectPreview(members)
            }
        case let .array(values):
            valueKind = .array
            text = values.isEmpty ? "[]" : "[\(values.count)]"
            isExpandable = !values.isEmpty
            if !isExpanded && !values.isEmpty {
                preview = Self.arrayPreview(values)
            }
        case let .string(string):
            valueKind = .string
            let leafExpanded = expandedLeaves.contains(nodeIndex)
            let display = Self.display(string, limit: leafExpanded ? 20_000 : 240)
            text = display.text
            isExpandable = display.truncated || leafExpanded
        case let .number(literal):
            valueKind = .number
            text = literal
        case let .bool(flag):
            valueKind = .bool
            text = flag ? "true" : "false"
        case .null:
            valueKind = .null
            text = "null"
        }
        return JSONTreeRow(
            id: nodeIndex,
            node: nodeIndex,
            kind: .node,
            depth: max(0, node.depth),
            key: key,
            isIndexKey: isIndexKey,
            valueKind: valueKind,
            text: text,
            preview: preview,
            childCount: node.childCount,
            isExpanded: isExpanded,
            isExpandable: isExpandable,
            isMatch: matches.contains(nodeIndex)
        )
    }

    private static func display(_ string: String, limit: Int) -> (text: String, truncated: Bool) {
        let prefix = string.prefix(limit)
        let truncated = prefix.endIndex < string.endIndex
        let escaped = JSONFormatting.escape(String(prefix))
        guard truncated else { return (escaped, false) }
        return (String(escaped.dropLast()) + "…\"", true)
    }

    private static func objectPreview(_ members: [JSONMember]) -> String {
        let keys = members.prefix(3).map { $0.key.count > 18 ? String($0.key.prefix(18)) + "…" : $0.key }
        return keys.joined(separator: ", ") + (members.count > 3 ? ", …" : "")
    }

    private static func arrayPreview(_ values: [JSONValue]) -> String {
        let items = values.prefix(3).map { value -> String in
            switch value {
            case .object: return "{…}"
            case .array: return "[…]"
            case let .string(string):
                let short = string.count > 16 ? String(string.prefix(16)) + "…" : string
                return JSONFormatting.escape(short)
            case let .number(literal): return literal
            case let .bool(flag): return flag ? "true" : "false"
            case .null: return "null"
            }
        }
        return items.joined(separator: ", ") + (values.count > 3 ? ", …" : "")
    }
}
