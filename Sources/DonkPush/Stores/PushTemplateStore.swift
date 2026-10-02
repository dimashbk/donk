import Combine
import DonkCore
import Foundation

final class PushTemplateStore: @unchecked Sendable {
    static let shared = PushTemplateStore()

    private let directory: URL?
    private let fileName: String
    private let lock = DonkLock()
    private var storedTemplates: [PushTemplate] = []
    private var isLoaded = false
    private let subject = PassthroughSubject<[PushTemplate], Never>()

    init(directory: URL? = nil, fileName: String = "push-templates.json") {
        self.directory = directory
        self.fileName = fileName
    }

    var templates: [PushTemplate] {
        lock.withLock {
            loadIfNeeded()
            return storedTemplates
        }
    }

    var changes: AnyPublisher<[PushTemplate], Never> {
        subject.eraseToAnyPublisher()
    }

    @discardableResult
    func add(name: String, payload: String) -> PushTemplate {
        let template = PushTemplate(name: Self.normalizedName(name), payload: payload)
        mutate { $0.insert(template, at: 0) }
        return template
    }

    func rename(_ id: UUID, to name: String) {
        mutate { templates in
            guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
            templates[index].name = Self.normalizedName(name)
        }
    }

    func updatePayload(_ id: UUID, payload: String) {
        mutate { templates in
            guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
            templates[index].payload = payload
        }
    }

    func remove(_ id: UUID) {
        mutate { $0.removeAll { $0.id == id } }
    }

    static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private func mutate(_ body: (inout [PushTemplate]) -> Void) {
        let snapshot: [PushTemplate] = lock.withLock {
            loadIfNeeded()
            body(&storedTemplates)
            save(storedTemplates)
            return storedTemplates
        }
        subject.send(snapshot)
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        if let directory {
            storedTemplates = DonkPersistence.load([PushTemplate].self, from: fileName, in: directory) ?? []
        } else {
            storedTemplates = DonkPersistence.load([PushTemplate].self, from: fileName) ?? []
        }
    }

    private func save(_ templates: [PushTemplate]) {
        if let directory {
            DonkPersistence.save(templates, to: fileName, in: directory)
        } else {
            DonkPersistence.save(templates, to: fileName)
        }
    }
}
