import Foundation

struct RecoveryRecord: Codable, Sendable {
    let version: Int
    let id: UUID
    let text: String
    let sourceURL: URL?
    let sourceBaseline: Data?
    let updated: Date
}

struct RecoveryStore {
    let directory: URL

    static func applicationStore() throws -> RecoveryStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        return RecoveryStore(directory: support.appendingPathComponent("mdwrite/Recovery", isDirectory: true))
    }

    func write(_ record: RecoveryRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url(for: record.id), options: .atomic)
    }

    func records() throws -> [RecoveryRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                // Preserve damaged/unknown records rather than destroying recovery evidence.
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data),
                      record.version == 1 else { return nil }
                return record
            }.sorted { $0.updated < $1.updated }
    }

    func remove(_ id: UUID) throws {
        let path = url(for: id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
