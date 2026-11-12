import Foundation

struct NetworkSelection: Equatable, Sendable {
    private(set) var ids: Set<UUID> = []

    init(_ ids: Set<UUID> = []) {
        self.ids = ids
    }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id)
    }

    mutating func toggle(_ id: UUID) {
        if ids.remove(id) == nil {
            ids.insert(id)
        }
    }

    mutating func insert(_ id: UUID) {
        ids.insert(id)
    }

    mutating func selectAll(_ visible: [UUID]) {
        ids = Set(visible)
    }

    mutating func removeAll() {
        ids.removeAll()
    }

    func covers(_ visible: [UUID]) -> Bool {
        guard !visible.isEmpty, ids.count >= visible.count else { return false }
        return visible.allSatisfy(ids.contains)
    }

    @discardableResult
    mutating func retain(_ visible: Set<UUID>) -> Bool {
        guard !ids.isSubset(of: visible) else { return false }
        ids.formIntersection(visible)
        return true
    }

    func ordered(_ visible: [UUID]) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        return visible.filter(ids.contains)
    }
}
