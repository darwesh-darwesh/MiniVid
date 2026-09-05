import Foundation
import Observation
import os

struct ProjectRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let config: GenerationConfig
    let seedUsed: UInt32
    let generationSeconds: Double
}

/// JSON-index persistence under Documents/Projects, with one folder per
/// generation (video.mp4 + thumb.png) so files stay browsable in the Files app.
@MainActor
@Observable
final class ProjectStore {

    private(set) var records: [ProjectRecord] = []

    private let logger = Logger(subsystem: "com.jt.minivid", category: "store")

    private var rootDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Projects", isDirectory: true)
    }

    private var indexURL: URL { rootDirectory.appendingPathComponent("index.json") }

    init() { load() }

    func directory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func videoURL(for record: ProjectRecord) -> URL {
        directory(for: record.id).appendingPathComponent("video.mp4")
    }

    func thumbnailURL(for record: ProjectRecord) -> URL {
        directory(for: record.id).appendingPathComponent("thumb.png")
    }

    func add(_ record: ProjectRecord) {
        records.insert(record, at: 0)
        save()
    }

    func delete(_ record: ProjectRecord) {
        records.removeAll { $0.id == record.id }
        try? FileManager.default.removeItem(at: directory(for: record.id))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            records = try JSONDecoder().decode([ProjectRecord].self, from: data)
        } catch {
            logger.error("Failed to decode project index: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Best-effort: the media files themselves remain on disk.
            logger.error("Failed to save project index: \(error.localizedDescription)")
        }
    }
}
