import AVKit
import SwiftUI

/// Community feed: clips shared by MiniVid users, streamed from the public
/// bucket. No accounts — a self-chosen handle, likes deduplicated locally.
struct FeedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    BrandHeader()
                    AuthorRow()

                    if let error = model.feed.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.magenta)
                            .multilineTextAlignment(.center)
                    }

                    if model.feed.posts.isEmpty {
                        if model.feed.isLoading {
                            ProgressView("Loading the feed…")
                                .tint(Theme.cyan)
                                .padding(.top, 60)
                        } else if model.feed.hasLoadedOnce {
                            ContentUnavailableView(
                                "Nothing here yet",
                                systemImage: "sparkles.tv",
                                description: Text("Generate a clip and be the first to share it.")
                            )
                        }
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(model.feed.posts) { post in
                                FeedPostCard(post: post)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await model.feed.refresh() }
            .task {
                if !model.feed.hasLoadedOnce { await model.feed.refresh() }
            }
            .background(CosmicBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// "Posting as" handle, editable in place.
private struct AuthorRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var feed = model.feed
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(Theme.accent)
            Text("Posting as")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            TextField("your handle", text: $feed.author)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.cyan)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.09)))
    }
}

private struct FeedPostCard: View {
    @Environment(AppModel.self) private var model
    let post: FeedPost
    @State private var showPlayer = false

    var body: some View {
        Button {
            showPlayer = true
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: model.feed.publicURL(for: post.thumbPath)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.06))
                            Image(systemName: "film")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                        .padding(5)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(post.prompt)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(post.author)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.cyan)
                        Text("·")
                            .foregroundStyle(.white.opacity(0.3))
                        Text(post.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    LikeButton(post: post)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPlayer) {
            FeedPostDetailView(post: post)
        }
    }
}

private struct LikeButton: View {
    @Environment(AppModel.self) private var model
    let post: FeedPost

    private var liked: Bool { model.feed.hasLiked(post) }
    private var count: Int {
        model.feed.posts.first(where: { $0.id == post.id })?.likes ?? post.likes
    }

    var body: some View {
        Button {
            Task { await model.feed.like(post) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: liked ? "heart.fill" : "heart")
                Text("\(count)")
                    .monospacedDigit()
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(liked ? Theme.magenta : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .disabled(liked)
    }
}

private struct FeedPostDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let post: FeedPost
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
                        Text(post.prompt)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                        HStack(spacing: 4) {
                            Text(post.author)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.cyan)
                            Text("·")
                                .foregroundStyle(.white.opacity(0.3))
                            Text(post.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 14) {
                        LikeButton(post: post)
                            .scaleEffect(1.3)
                        ShareLink(item: model.feed.publicURL(for: post.videoPath)) {
                            Label("Share link", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(Theme.accent, in: Capsule())
                                .shadow(color: Theme.violet.opacity(0.5), radius: 10)
                        }
                    }
                }
                .padding(16)
            }
            .background(CosmicBackground())
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Theme.cyan)
                }
            }
            .onAppear {
                let newPlayer = AVPlayer(url: model.feed.publicURL(for: post.videoPath))
                newPlayer.play()
                player = newPlayer
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Shared "Publish to feed" control used by ResultView and History.
struct PublishToFeedButton: View {
    @Environment(AppModel.self) private var model
    let record: ProjectRecord

    var body: some View {
        if model.feed.isPublished(record.id) {
            Label("On the feed", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.white.opacity(0.06), in: Capsule())
        } else if model.feed.isPublishing {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Theme.cyan)
                Text("Publishing…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        } else {
            Button {
                Task {
                    _ = await model.feed.publish(
                        record: record,
                        videoURL: model.store.videoURL(for: record),
                        thumbURL: model.store.thumbnailURL(for: record)
                    )
                }
            } label: {
                Label("Publish to feed", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
                    .shadow(color: Theme.violet.opacity(0.5), radius: 10)
            }
            .buttonStyle(.plain)
        }
    }
}
