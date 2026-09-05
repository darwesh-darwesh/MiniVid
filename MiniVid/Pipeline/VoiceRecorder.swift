import AVFAudio
import Foundation
import Observation

/// Records a voiceover to a temporary AAC file, to be mixed over the
/// exported video by `AudioComposer.overlayVoice`.
@MainActor
@Observable
final class VoiceRecorder {

    private(set) var isRecording = false
    private(set) var recordedURL: URL?
    var errorMessage: String?

    private var recorder: AVAudioRecorder?

    func start() async {
        errorMessage = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access denied — enable it in Settings."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voiceover-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            recordedURL = nil
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        recorder?.stop()
        recordedURL = recorder?.url
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func discard() {
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recordedURL = nil
    }
}
