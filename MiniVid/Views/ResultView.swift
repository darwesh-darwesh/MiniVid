import AVKit
import SwiftUI

struct ResultView: View {
    let result: GenerationResult

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var gifURL: URL?
    @State private var isExportingGIF = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VideoPlayer(player: player)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(Theme.accent, lineWidth: 1.5)
                                .opacity(0.6)
                        )
                        .shadow(color: Theme.violet.opacity(0.4), radius: 24)
                        .onAppear {
                            let newPlayer = AVPlayer(url: result.videoURL)
                            newPlayer.play()
                            player = newPlayer
                        }

                    VStack(spacing: 6) {
                        Text(result.record.config.prompt)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                        Text("Seed \(result.record.seedUsed) · \(result.frames.count) frames @ \(result.exportFPS) fps · rendered in \(Int(result.record.generationSeconds)) s")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        ShareLink(item: result.videoURL) {
                            Label("Share MP4", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(Theme.accent, in: Capsule())
                                .shadow(color: Theme.violet.opacity(0.5), radius: 10)
                        }

                        if let gifURL {
                            ShareLink(item: gifURL) {
                                gifLabel(icon: "square.and.arrow.up", text: "Share GIF")
                            }
                        } else {
                            Button {
                                exportGIF()
                            } label: {
                                if isExportingGIF {
                                    ProgressView()
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 12)
                                } else {
                                    gifLabel(icon: "photo.stack", text: "Make GIF")
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isExportingGIF)
                        }
                    }

                    PublishToFeedButton(record: result.record)
                    if let feedError = model.feed.errorMessage {
                        Text(feedError)
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta)
                    }

                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta)
                    }

                    VoiceoverCard(videoURL: result.videoURL, player: $player, errorMessage: $exportError)
                }
                .padding(16)
            }
            .background(CosmicBackground())
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Theme.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func gifLabel(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    private func exportGIF() {
        isExportingGIF = true
        let frames = result.frames
        let fps = result.exportFPS
        let url = result.videoURL.deletingLastPathComponent().appendingPathComponent("video.gif")
        Task.detached(priority: .userInitiated) {
            do {
                try VideoExporter.writeGIF(frames: frames, fps: fps, to: url)
                await MainActor.run {
                    gifURL = url
                    isExportingGIF = false
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isExportingGIF = false
                }
            }
        }
    }
}

/// Record a voiceover and mix it over the exported MP4 (existing soundtrack
/// is kept, ducked to half volume).
private struct VoiceoverCard: View {
    let videoURL: URL
    @Binding var player: AVPlayer?
    @Binding var errorMessage: String?

    @State private var recorder = VoiceRecorder()
    @State private var isApplying = false

    var body: some View {
        GlassCard(icon: "mic.fill", title: "Voiceover") {
            if isApplying {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Theme.cyan)
                    Text("Mixing voiceover into the video…")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else if recorder.isRecording {
                Button {
                    recorder.stop()
                } label: {
                    Label("Stop recording", systemImage: "stop.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.magenta, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            } else if let voiceURL = recorder.recordedURL {
                HStack(spacing: 10) {
                    Button {
                        apply(voiceURL)
                    } label: {
                        Label("Mix into video", systemImage: "waveform.badge.plus")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        recorder.discard()
                        Task { await recorder.start() }
                    } label: {
                        Label("Re-record", systemImage: "arrow.counterclockwise")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.cyan)
                    }
                    .buttonStyle(.plain)
                    Button {
                        recorder.discard()
                    } label: {
                        Image(systemName: "trash")
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    player?.pause()
                    Task { await recorder.start() }
                } label: {
                    Label("Record voiceover", systemImage: "mic.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Theme.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        )
                }
                .buttonStyle(.plain)
            }
            if let recorderError = recorder.errorMessage {
                Text(recorderError)
                    .font(.caption)
                    .foregroundStyle(Theme.magenta)
            }
        }
    }

    private func apply(_ voiceURL: URL) {
        isApplying = true
        let target = videoURL
        Task {
            do {
                let mixed = target.deletingLastPathComponent().appendingPathComponent("video_voiceover.mp4")
                try await AudioComposer.overlayVoice(videoURL: target, voiceURL: voiceURL, to: mixed)
                _ = try FileManager.default.replaceItemAt(target, withItemAt: mixed)
                await MainActor.run {
                    recorder.discard()
                    let newPlayer = AVPlayer(url: target)
                    newPlayer.play()
                    player = newPlayer
                    isApplying = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isApplying = false
                }
            }
        }
    }
}
