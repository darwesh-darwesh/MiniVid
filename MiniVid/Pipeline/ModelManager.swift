import Foundation
import Observation
import ZIPFoundation

/// Downloads, unpacks and locates Core ML model resources under
/// Documents/Models. Models can also be dropped in manually via the Files app
/// (file sharing is enabled), then picked up with `refresh()`.
@MainActor
@Observable
final class ModelManager {

    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case unpacking
        case ready(URL)
        case failed(String)
    }

    struct ModelOption: Identifiable {
        let id: String
        let name: String
        let detail: String
        let url: URL
    }

    /// Palettized (~6-bit) Core ML builds published by Apple. `split_einsum`
    /// targets the Neural Engine, which is what low-RAM iPads need; the
    /// `original` attention variant is faster on Mac GPUs.
    static let options: [ModelOption] = [
        ModelOption(
            id: "sd21-palettized-ane",
            name: "Stable Diffusion 2.1 base — Neural Engine",
            detail: "~1.2 GB download · palettized · recommended on iPhone/iPad",
            url: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip")!
        ),
        ModelOption(
            id: "sd21-palettized-gpu",
            name: "Stable Diffusion 2.1 base — GPU",
            detail: "~1.2 GB download · palettized · better on Macs",
            url: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/coreml-stable-diffusion-2-1-base-palettized_original_compiled.zip")!
        ),
    ]

    struct InstalledModel: Identifiable, Equatable {
        let url: URL

        var id: String { url.lastPathComponent }

        /// Shortened display name for the UI.
        var name: String {
            url.lastPathComponent
                .replacingOccurrences(of: "coreml-stable-diffusion-", with: "SD ")
                .replacingOccurrences(of: "-palettized", with: "")
                .replacingOccurrences(of: "_compiled", with: "")
                .replacingOccurrences(of: "_", with: " ")
        }
    }

    var status: Status = .notInstalled
    private(set) var installed: [InstalledModel] = []

    private let activeModelKey = "MiniVid.activeModel"

    private var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Models", isDirectory: true)
    }

    init() { refresh() }

    /// Re-scan the models directory (after a download, a manual Files-app
    /// drop, or a deletion) and restore the previously selected model.
    func refresh() {
        if case .downloading = status { return }
        if case .unpacking = status { return }
        installed = scanInstalled()
        let storedID = UserDefaults.standard.string(forKey: activeModelKey)
        if let active = installed.first(where: { $0.id == storedID }) ?? installed.first {
            UserDefaults.standard.set(active.id, forKey: activeModelKey)
            status = .ready(active.url)
        } else {
            status = .notInstalled
        }
    }

    var activeModel: InstalledModel? {
        guard case .ready(let url) = status else { return nil }
        return installed.first { $0.url == url }
    }

    func select(_ model: InstalledModel) {
        UserDefaults.standard.set(model.id, forKey: activeModelKey)
        status = .ready(model.url)
    }

    func delete(_ model: InstalledModel) {
        try? FileManager.default.removeItem(at: model.url)
        if case .ready(let url) = status, url == model.url {
            status = .notInstalled
        }
        refresh()
    }

    /// Sideload a model from the Files app: either a compiled-resources
    /// folder or a zip of one (e.g. produced by scripts/convert_sd_turbo.sh).
    func importModel(from pickedURL: URL) async {
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            status = .unpacking
            if pickedURL.hasDirectoryPath {
                let destination = modelsDirectory.appendingPathComponent(pickedURL.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try await Self.copyItem(from: pickedURL, to: destination)
            } else {
                let localZip = modelsDirectory.appendingPathComponent("import.zip")
                try? FileManager.default.removeItem(at: localZip)
                try await Self.copyItem(from: pickedURL, to: localZip)
                try await Self.unzip(localZip, into: modelsDirectory)
                try? FileManager.default.removeItem(at: localZip)
            }
            status = .notInstalled
            refresh()
            if case .notInstalled = status {
                status = .failed("No Core ML resources found in the imported item.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func copyItem(from source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    func install(_ option: ModelOption) async {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            status = .downloading(0)
            let zipURL = modelsDirectory.appendingPathComponent("\(option.id).zip")
            try await Self.download(from: option.url, to: zipURL) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(fraction)
                }
            }
            status = .unpacking
            try await Self.unzip(zipURL, into: modelsDirectory)
            try? FileManager.default.removeItem(at: zipURL)
            status = .notInstalled
            refresh()
            if case .notInstalled = status {
                status = .failed("Archive unpacked but no Core ML resources were found.")
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// A valid resource folder is one containing TextEncoder.mlmodelc.
    /// Zips unpack either flat or one level deep, so scan both levels.
    private func scanInstalled() -> [InstalledModel] {
        let fm = FileManager.default
        func isModelDir(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.appendingPathComponent("TextEncoder.mlmodelc").path)
        }
        guard let level1 = try? fm.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for dir in level1 {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if isModelDir(dir) {
                found.append(dir)
            } else if let level2 = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                found.append(contentsOf: level2.filter(isModelDir))
            }
        }
        return found
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { InstalledModel(url: $0) }
    }

    private nonisolated static func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let total = response.expectedContentLength

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let flushThreshold = 4 << 20
        var buffer = Data()
        buffer.reserveCapacity(flushThreshold)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= flushThreshold {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { onProgress(Double(written) / Double(total)) }
            }
        }
        try handle.write(contentsOf: buffer)
    }

    private nonisolated static func unzip(_ zipURL: URL, into directory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.unzipItem(at: zipURL, to: directory)
        }.value
    }
}
