import CoreGraphics
import CoreML
import Foundation
import StableDiffusion

enum GenerationError: LocalizedError {
    case emptyOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyOutput:
            return "The pipeline returned no image (possibly flagged by the safety checker). Try another prompt or seed."
        case .cancelled:
            return "Generation was cancelled."
        }
    }
}

/// Wraps Apple's Core ML Stable Diffusion pipeline and drives the
/// keyframe + img2img feedback loop that turns single images into motion:
/// frame 0 is text→image, every following frame is a camera transform of the
/// previous frame re-noised through img2img at `motionStrength`.
final class VideoGenerator: @unchecked Sendable {

    struct Progress {
        let frameIndex: Int
        let frameCount: Int
        let step: Int
        let stepCount: Int
        let latestFrame: CGImage?
    }

    private let pipeline: StableDiffusionPipeline
    private var isCancelled = false

    init(resourcesAt url: URL, computeUnits: MLComputeUnits, reduceMemory: Bool) throws {
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = computeUnits
        pipeline = try StableDiffusionPipeline(
            resourcesAt: url,
            controlNet: [],
            configuration: mlConfig,
            disableSafety: false,
            reduceMemory: reduceMemory
        )
    }

    func cancel() { isCancelled = true }

    /// - Parameter initImage: optional 512² picked photo — image→video mode.
    ///   Frame 0 then runs img2img from it at `config.initImageStrength`
    ///   instead of pure text→image.
    func generate(
        config: GenerationConfig,
        initImage: CGImage? = nil,
        onProgress: @escaping (Progress) -> Void
    ) throws -> [CGImage] {
        isCancelled = false
        let seed = config.seed ?? UInt32.random(in: 1..<UInt32.max)
        var frames: [CGImage] = []
        frames.reserveCapacity(config.frameCount)
        // Palette anchor for the coherence stabilizer: the I2V photo when
        // present, otherwise the first generated frame.
        var colorReference: CGImage? = initImage

        for i in 0..<config.frameCount {
            if isCancelled { throw GenerationError.cancelled }

            var pc = StableDiffusionPipeline.Configuration(prompt: config.prompt(forFrame: i))
            pc.negativePrompt = config.negativePrompt
            pc.stepCount = config.stepCount
            pc.guidanceScale = config.guidanceScale
            pc.schedulerType = .dpmSolverMultistepScheduler
            pc.seed = seed &+ UInt32(i)
            if let previous = frames.last {
                pc.startingImage = CameraTransform.apply(config.cameraMove, to: previous, amount: config.cameraAmount)
                pc.strength = config.motionStrength
            } else if let initImage {
                pc.startingImage = initImage
                pc.strength = config.initImageStrength
            }

            let previousFrame = frames.last
            let images = try pipeline.generateImages(configuration: pc) { progress in
                onProgress(Progress(
                    frameIndex: i,
                    frameCount: config.frameCount,
                    step: progress.step,
                    stepCount: progress.stepCount,
                    latestFrame: previousFrame
                ))
                return !self.isCancelled
            }

            if isCancelled { throw GenerationError.cancelled }
            guard let rawFrame = images.compactMap({ $0 }).first else {
                throw GenerationError.emptyOutput
            }

            let frame: CGImage
            if let reference = colorReference, config.coherence > 0 {
                frame = CoherenceStabilizer.stabilize(
                    rawFrame,
                    reference: reference,
                    previous: pc.startingImage,
                    amount: config.coherence
                )
            } else {
                frame = rawFrame
            }
            if colorReference == nil { colorReference = frame }

            frames.append(frame)
            onProgress(Progress(
                frameIndex: i,
                frameCount: config.frameCount,
                step: config.stepCount,
                stepCount: config.stepCount,
                latestFrame: frame
            ))
        }

        return frames
    }

    /// Single text→image generation for the Studio tab's Image Lab.
    func generateStill(
        prompt: String,
        negativePrompt: String,
        stepCount: Int,
        guidanceScale: Float,
        seed: UInt32,
        onProgress: @escaping (Int, Int) -> Void
    ) throws -> CGImage {
        isCancelled = false
        var pc = StableDiffusionPipeline.Configuration(prompt: prompt)
        pc.negativePrompt = negativePrompt
        pc.stepCount = stepCount
        pc.guidanceScale = guidanceScale
        pc.schedulerType = .dpmSolverMultistepScheduler
        pc.seed = seed

        let images = try pipeline.generateImages(configuration: pc) { progress in
            onProgress(progress.step, progress.stepCount)
            return !self.isCancelled
        }
        if isCancelled { throw GenerationError.cancelled }
        guard let image = images.compactMap({ $0 }).first else {
            throw GenerationError.emptyOutput
        }
        return image
    }
}
