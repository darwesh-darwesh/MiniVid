import CoreGraphics
import CoreML
import Foundation
import Observation
import os

/// Result of the latest generation, kept in memory for instant playback.
struct GenerationResult {
    let record: ProjectRecord
    let frames: [CGImage]
    let videoURL: URL
    /// FPS after frame blending — what the MP4/GIF actually plays at.
    let exportFPS: Int
}

@MainActor
@Observable
final class AppModel {

    let modelManager: ModelManager
    let store: ProjectStore
    let feed: FeedService

    var config: GenerationConfig
    /// Picked photo for image→video, already center-cropped to 512².
    var inputImage: CGImage?
    /// User-imported soundtrack (copied into Documents/ImportedAudio).
    var customAudioURL: URL?
    var isGenerating = false
    // Studio tab: single-image generation.
    var isGeneratingStill = false
    var stillImage: CGImage?
    var stillProgressText = ""
    var progressFraction: Double = 0
    var progressText = ""
    var etaText: String?
    var latestFrame: CGImage?
    var lastResult: GenerationResult?
    var showResult = false
    var errorMessage: String?

    private var generator: VideoGenerator?
    private var generatorModelURL: URL?
    private var generationStartedAt: Date?
    private let logger = Logger(subsystem: "com.jt.minivid", category: "generation")

    init() {
        modelManager = ModelManager()
        store = ProjectStore()
        feed = FeedService()
        var config = GenerationConfig()
        config.resolution = DeviceProfile.current.defaultResolution
        config.frameCount = min(16, DeviceProfile.current.maxFrames)
        self.config = config
    }

    func generate() async {
        guard case .ready(let modelURL) = modelManager.status, !isGenerating else { return }
        guard !config.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a prompt first."
            return
        }

        isGenerating = true
        errorMessage = nil
        latestFrame = nil
        etaText = nil
        progressFraction = 0

        do {
            let generator = try await loadGeneratorIfNeeded(at: modelURL)
            progressText = "Generating frame 1/\(config.frameCount)…"

            var effective = config
            effective.seed = config.seed ?? UInt32.random(in: 1..<UInt32.max)
            let started = Date()
            generationStartedAt = started

            let initImage = inputImage
            let frames = try await Task.detached(priority: .userInitiated) { [effective] in
                try generator.generate(config: effective, initImage: initImage) { progress in
                    Task { @MainActor [weak self] in self?.apply(progress) }
                }
            }.value

            let elapsed = Date().timeIntervalSince(started)
            logger.info("Generated \(frames.count) frames in \(elapsed, format: .fixed(precision: 1)) s")
            try await finish(frames: frames, config: effective, seconds: elapsed)
        } catch GenerationError.cancelled {
            progressText = ""
        } catch {
            logger.error("Generation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isGenerating = false
        etaText = nil
        generationStartedAt = nil
    }

    func cancel() {
        generator?.cancel()
        progressText = "Cancelling…"
    }

    /// Studio tab: generate a single 512² image with the loaded pipeline.
    func generateStill(prompt: String, steps: Int, seed: UInt32?) async {
        guard case .ready(let modelURL) = modelManager.status,
              !isGenerating, !isGeneratingStill,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        isGeneratingStill = true
        stillImage = nil
        stillProgressText = "Loading model…"

        do {
            let generator = try await loadGeneratorIfNeeded(at: modelURL)
            let negative = config.negativePrompt
            let guidance = config.guidanceScale
            let seedUsed = seed ?? UInt32.random(in: 1..<UInt32.max)
            stillProgressText = "Dreaming…"

            let image = try await Task.detached(priority: .userInitiated) {
                try generator.generateStill(
                    prompt: prompt,
                    negativePrompt: negative,
                    stepCount: steps,
                    guidanceScale: guidance,
                    seed: seedUsed
                ) { step, total in
                    Task { @MainActor [weak self] in
                        self?.stillProgressText = "Step \(min(step + 1, total))/\(total)"
                    }
                }
            }.value
            stillImage = image
            stillProgressText = ""
        } catch GenerationError.cancelled {
            stillProgressText = ""
        } catch {
            logger.error("Still generation failed: \(error.localizedDescription)")
            stillProgressText = error.localizedDescription
        }
        isGeneratingStill = false
    }

    private func loadGeneratorIfNeeded(at modelURL: URL) async throws -> VideoGenerator {
        if let generator, generatorModelURL == modelURL { return generator }

        progressText = "Loading model (first run compiles for this device — this can take a few minutes)…"
        // The Mac's ANE rejects these iPad split_einsum programs
        // (ANEProgramProcessRequestDirect error 0x16), so route to the GPU
        // when running as "Designed for iPad" on Apple Silicon.
        let computeUnits: MLComputeUnits = ProcessInfo.processInfo.isiOSAppOnMac ? .cpuAndGPU : .cpuAndNeuralEngine
        let reduceMemory = DeviceProfile.current.reduceMemory

        let generator = try await Task.detached(priority: .userInitiated) {
            try VideoGenerator(resourcesAt: modelURL, computeUnits: computeUnits, reduceMemory: reduceMemory)
        }.value
        self.generator = generator
        self.generatorModelURL = modelURL
        return generator
    }

    private func apply(_ progress: VideoGenerator.Progress) {
        let frameProgress = min(Double(progress.step) / Double(max(progress.stepCount, 1)), 1)
        progressFraction = (Double(progress.frameIndex) + frameProgress) / Double(progress.frameCount)
        progressText = "Frame \(progress.frameIndex + 1)/\(progress.frameCount) · step \(min(progress.step + 1, progress.stepCount))/\(progress.stepCount)"
        if let frame = progress.latestFrame { latestFrame = frame }

        // ETA from the observed pace; wait a few seconds so it doesn't jump.
        if let start = generationStartedAt {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 5, progressFraction > 0.03 {
                let remaining = elapsed * (1 - progressFraction) / progressFraction
                etaText = "~\(Self.formatDuration(remaining)) left"
            }
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    private func finish(frames: [CGImage], config: GenerationConfig, seconds: Double) async throws {
        let record = ProjectRecord(
            id: UUID(),
            createdAt: .now,
            config: config,
            seedUsed: config.seed ?? 0,
            generationSeconds: seconds
        )
        let directory = store.directory(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scaled = frames.map { VideoExporter.resize($0, to: config.resolution.pixels) }
        let videoURL = store.videoURL(for: record)

        let outputFrames: [CGImage]
        if config.smoothing != .off {
            progressText = "Smoothing motion (×\(config.smoothing.rawValue))…"
            outputFrames = await Task.detached(priority: .userInitiated) {
                FrameInterpolator.smooth(scaled, factor: config.smoothing.rawValue)
            }.value
        } else {
            outputFrames = scaled
        }
        let exportFPS = config.exportFPS

        if config.soundStyle == .none || (config.soundStyle == .imported && customAudioURL == nil) {
            progressText = "Exporting MP4…"
            try await VideoExporter.writeMP4(frames: outputFrames, fps: exportFPS, to: videoURL)
        } else if config.soundStyle == .imported, let customAudioURL {
            progressText = "Rendering video…"
            let silentURL = directory.appendingPathComponent("video_silent.mp4")
            try await VideoExporter.writeMP4(frames: outputFrames, fps: exportFPS, to: silentURL)

            progressText = "Adding your soundtrack…"
            try await AudioComposer.mux(
                silentVideoURL: silentURL,
                audioFileURL: customAudioURL,
                to: videoURL,
                volume: config.soundVolume
            )
            try? FileManager.default.removeItem(at: silentURL)
        } else {
            progressText = "Rendering video…"
            let silentURL = directory.appendingPathComponent("video_silent.mp4")
            try await VideoExporter.writeMP4(frames: outputFrames, fps: exportFPS, to: silentURL)

            progressText = "Composing soundscape…"
            let seed = config.seed ?? 0
            let samples = await Task.detached(priority: .userInitiated) {
                AudioGenerator.render(style: config.soundStyle, config: config, seed: seed)
            }.value
            let audioURL = directory.appendingPathComponent("audio.caf")
            try AudioComposer.writePCM(samples, sampleRate: AudioGenerator.sampleRate, to: audioURL)

            progressText = "Adding sound…"
            try await AudioComposer.mux(silentVideoURL: silentURL, audioFileURL: audioURL, to: videoURL)

            try? FileManager.default.removeItem(at: silentURL)
            try? FileManager.default.removeItem(at: audioURL)
        }

        try VideoExporter.writePNG(VideoExporter.resize(frames[0], to: 256), to: store.thumbnailURL(for: record))

        // Keep the source photo alongside the project: seed alone can't
        // reproduce an image→video run.
        if let inputImage {
            try? VideoExporter.writePNG(inputImage, to: directory.appendingPathComponent("input.png"))
        }

        store.add(record)
        lastResult = GenerationResult(record: record, frames: outputFrames, videoURL: videoURL, exportFPS: exportFPS)
        showResult = true
        progressText = ""
        progressFraction = 1
    }
}
