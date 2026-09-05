import Foundation

/// Deterministic xorshift RNG so the same seed always renders the same
/// soundscape, matching the reproducibility of the video pipeline.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt32) { state = UInt64(seed) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Synthesizes a short ambient soundscape entirely on-device — a few sine
/// oscillators plus filtered noise, no ML model and no samples. Kept
/// deliberately lo-fi (mono, 22.05 kHz) to match the project's cheap,
/// fully-offline philosophy rather than aiming for musical realism.
enum AudioGenerator {
    static let sampleRate: Double = 22_050

    static func render(style: SoundStyle, config: GenerationConfig, seed: UInt32) -> [Float] {
        guard style != .none, style != .imported else { return [] }

        let duration = config.durationSeconds
        let sampleCount = max(1, Int(duration * sampleRate))
        var samples = [Float](repeating: 0, count: sampleCount)
        var rng = SeededRNG(seed: seed)

        let baseFreq = 48.0 + Double(seed % 60)            // 48-108 Hz drone root
        let detune = 1.0 + Double((seed >> 8) % 7) * 0.003  // subtle beating between layers
        // The melody sits on top of a quieter drone bed.
        let droneLevel = style == .melody ? 0.35 : 1.0

        // Mini music composer: a seeded pentatonic arpeggio. The register
        // shifts up a fourth on each storyboard scene change.
        let noteRate = 3.0
        var noteFreqs: [Double] = []
        if style == .melody {
            let scale: [Double] = [0, 3, 5, 7, 10, 12]
            let sceneCount = max(config.activeScenes.count, 1)
            let noteCount = Int(duration * noteRate) + 1
            var noteRng = SeededRNG(seed: seed ^ 0x5EED)
            let root = 110.0 * pow(2, Double(seed % 12) / 12)
            for k in 0..<noteCount {
                let progress = Double(k) / Double(max(noteCount - 1, 1))
                let scene = min(sceneCount - 1, Int(progress * Double(sceneCount)))
                let degree = scale[Int(noteRng.next() % UInt64(scale.count))]
                let octave = Double(noteRng.next() % 2)
                noteFreqs.append(root * pow(2, (degree + Double(scene) * 5) / 12) * pow(2, octave))
            }
        }

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            var sample = 0.0

            // Drone layer: two slightly detuned sines under a slow amplitude LFO.
            let lfo = 0.6 + 0.4 * sin(2 * .pi * 0.15 * t)
            sample += droneLevel * 0.5 * lfo * sin(2 * .pi * baseFreq * t)
            sample += droneLevel * 0.35 * lfo * sin(2 * .pi * baseFreq * detune * t)

            if style == .melody, !noteFreqs.isEmpty {
                let k = min(Int(t * noteRate), noteFreqs.count - 1)
                let phase = t * noteRate - Double(k)
                let envelope = exp(-4 * phase)
                let f = noteFreqs[k]
                sample += 0.5 * envelope * sin(2 * .pi * f * t)
                sample += 0.15 * envelope * sin(4 * .pi * f * t)   // soft octave shimmer
            }

            if style == .driftingDrone {
                let drift = baseFreq * (1 + 0.02 * sin(2 * .pi * 0.05 * t))
                sample += 0.25 * sin(2 * .pi * drift * 2 * t)
            }

            if style == .rhythmicPulse {
                let beatHz = Double(config.fps) / 4.0
                let phase = (t * beatHz).truncatingRemainder(dividingBy: 1)
                let pulse = phase < 0.08 ? (1 - phase / 0.08) : 0
                sample += 0.4 * pulse * sin(2 * .pi * (baseFreq * 3) * t)
            }

            // Motion layer: noise swell synced to the camera move's amount,
            // silent when the camera is fixed.
            if config.cameraMove != .fixed {
                let noise = Double.random(in: -1...1, using: &rng)
                let sweepHz = 0.2 + Double(config.cameraAmount) * 0.6
                let swell = 0.5 + 0.5 * sin(2 * .pi * sweepHz * t - .pi / 2)
                sample += 0.15 * Double(config.cameraAmount) * swell * noise
            }

            samples[i] = Float(sample)
        }

        applyFades(&samples, sampleRate: sampleRate)
        normalize(&samples, peak: config.soundVolume)
        return samples
    }

    private static func applyFades(_ samples: inout [Float], sampleRate: Double) {
        let fadeSamples = min(samples.count / 2, Int(0.15 * sampleRate))
        guard fadeSamples > 0 else { return }
        for i in 0..<fadeSamples {
            let gain = Float(i) / Float(fadeSamples)
            samples[i] *= gain
            samples[samples.count - 1 - i] *= gain
        }
    }

    private static func normalize(_ samples: inout [Float], peak: Float) {
        guard let maxAbs = samples.map({ abs($0) }).max(), maxAbs > 0 else { return }
        let scale = peak / maxAbs
        for i in samples.indices { samples[i] *= scale }
    }
}
