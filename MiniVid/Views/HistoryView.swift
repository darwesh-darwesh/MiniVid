import AVKit
import SwiftUI
import UIKit

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ProjectRecord?

    var body: some View {
        NavigationStack {
            Group {
                if model.store.records.isEmpty {
                    ContentUnavailableView(
                        "No videos yet",
                        systemImage: "film.stack",
                        description: Text("Generated videos appear here.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            BrandHeader()
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                                spacing: 14
                            ) {
                                ForEach(model.store.records) { record in
                                    Button {
                                        selected = record
                                    } label: {
                                        HistoryCard(record: record)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            model.store.delete(record)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(CosmicBackground())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selected) { record in
                HistoryDetailView(record: record)
            }
        }
    }
}

private struct HistoryCard: View {
    @Environment(AppModel.self) private var model
    let record: ProjectRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = UIImage(contentsOfFile: model.store.thumbnailURL(for: record).path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.06))
                            Image(systemName: "film")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))

            Text(record.config.prompt)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.white.opacity(0.85))
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: ProjectRecord
    @State private var player: AVPlayer?

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

                    VStack(spacing: 6) {
                        Text(record.config.prompt)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                        Text("Seed \(record.seedUsed) · \(record.config.stepCount) steps · motion \(String(format: "%.2f", record.config.motionStrength)) · \(record.config.cameraMove.label)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        ShareLink(item: model.store.videoURL(for: record)) {
                            Label("Share MP4", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(Theme.accent, in: Capsule())
                                .shadow(color: Theme.violet.opacity(0.5), radius: 10)
                        }
                        PublishToFeedButton(record: record)
                    }
                    if let feedError = model.feed.errorMessage {
                        Text(feedError)
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta)
                    }
                }
                .padding(16)
            }
            .background(CosmicBackground())
            .navigationTitle(record.createdAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Theme.cyan)
                }
            }
            .onAppear {
                let newPlayer = AVPlayer(url: model.store.videoURL(for: record))
                newPlayer.play()
                player = newPlayer
            }
        }
        .preferredColorScheme(.dark)
    }
}
