import AVFoundation
import Foundation

enum AudioMuxError: LocalizedError {
    case missingTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTrack:
            return "Could not read the source video or audio track."
        case .exportFailed(let reason):
            return "Adding sound failed: \(reason)"
        }
    }
}

/// Writes procedurally generated PCM samples to disk and muxes them with an
/// already-rendered silent MP4 into a final MP4 carrying an AAC audio track.
enum AudioComposer {

    static func writePCM(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw AudioMuxError.exportFailed("Could not create audio format")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioMuxError.exportFailed("Could not allocate audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func mux(silentVideoURL: URL, audioFileURL: URL, to outputURL: URL, volume: Float = 1) async throws {
        let videoAsset = AVURLAsset(url: silentVideoURL)
        let audioAsset = AVURLAsset(url: audioFileURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else { throw AudioMuxError.missingTrack }

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AudioMuxError.missingTrack }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let sharedAudioDuration = CMTimeMinimum(videoDuration, audioDuration)

        try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        try compAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: sharedAudioDuration), of: audioTrack, at: .zero)

        var mix: AVMutableAudioMix?
        if volume < 0.999 {
            let params = AVMutableAudioMixInputParameters(track: compAudioTrack)
            params.setVolume(volume, at: .zero)
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [params]
            mix = audioMix
        }
        try await export(composition, audioMix: mix, to: outputURL)
    }

    /// Mixes a voiceover on top of an already-exported video, keeping the
    /// existing soundtrack (ducked) if there is one.
    static func overlayVoice(
        videoURL: URL,
        voiceURL: URL,
        to outputURL: URL,
        voiceVolume: Float = 1.0,
        originalVolume: Float = 0.5
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let voiceAsset = AVURLAsset(url: voiceURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let voiceTrack = try await voiceAsset.loadTracks(withMediaType: .audio).first
        else { throw AudioMuxError.missingTrack }
        let originalAudioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compVoiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AudioMuxError.missingTrack }

        let videoDuration = try await videoAsset.load(.duration)
        let voiceDuration = try await voiceAsset.load(.duration)
        try compVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        try compVoiceTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, voiceDuration)),
            of: voiceTrack,
            at: .zero
        )

        let voiceParams = AVMutableAudioMixInputParameters(track: compVoiceTrack)
        voiceParams.setVolume(voiceVolume, at: .zero)
        var inputParameters = [voiceParams]

        if let originalAudioTrack,
           let compOriginalTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compOriginalTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: originalAudioTrack, at: .zero)
            let originalParams = AVMutableAudioMixInputParameters(track: compOriginalTrack)
            originalParams.setVolume(originalVolume, at: .zero)
            inputParameters.append(originalParams)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = inputParameters
        try await export(composition, audioMix: mix, to: outputURL)
    }

    private static func export(_ composition: AVMutableComposition, audioMix: AVMutableAudioMix?, to outputURL: URL) async throws {
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AudioMuxError.exportFailed("Could not create export session")
        }
        try? FileManager.default.removeItem(at: outputURL)
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.audioMix = audioMix

        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw AudioMuxError.exportFailed(export.error?.localizedDescription ?? "unknown export error")
        }
    }
}
