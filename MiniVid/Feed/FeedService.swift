import Foundation
import Observation

struct FeedPost: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let author: String
    let prompt: String
    let videoPath: String
    let thumbPath: String
    let durationSeconds: Double?
    var likes: Int

    enum CodingKeys: String, CodingKey {
        case id, author, prompt, likes
        case createdAt = "created_at"
        case videoPath = "video_path"
        case thumbPath = "thumb_path"
        case durationSeconds = "duration_seconds"
    }
}

/// Shown whenever the build carries no backend. Top-level, so it is not
/// main-actor isolated and stays readable from FeedError.
let feedNotConfiguredMessage =
    "Community feed not configured. Copy Secrets.example.xcconfig to "
    + "Secrets.xcconfig, fill in your own Supabase project, and rebuild."

enum FeedError: LocalizedError {
    case videoTooLarge
    case server(Int, String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .videoTooLarge:
            return "This video is over the 25 MB feed limit."
        case .server(let code, let message):
            return "Feed error (\(code)): \(message)"
        case .notConfigured:
            return feedNotConfiguredMessage
        }
    }
}

/// REST client for the community feed (Supabase PostgREST + Storage).
/// No accounts: posts carry a self-chosen handle; likes are deduplicated
/// locally. Content is public to everyone running the app.
@MainActor
@Observable
final class FeedService {

    // Supabase credentials come from the build, never from source. The anon key
    // is publishable *only* to the extent the row-level-security policies of
    // the project behind it are known to be correct -- which is a property of
    // that project, not of the key. Hardcoding it here shipped one specific
    // backend's key with the repository and made it impossible to point the
    // app somewhere else without editing code.
    //
    // Set both in Secrets.xcconfig (git-ignored, see Secrets.example.xcconfig).
    // Absent, the feed is simply off: nothing is attempted, nothing fails oddly.
    private static let baseURL: URL? = infoValue("MiniVidSupabaseURL").flatMap(URL.init(string:))
    private static let anonKey: String? = infoValue("MiniVidSupabaseAnonKey")

    /// A non-empty Info.plist string, or nil. Empty means "not configured".
    private static func infoValue(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when the build carries a backend to talk to.
    static var isConfigured: Bool { baseURL != nil && anonKey != nil }

    private(set) var posts: [FeedPost] = []
    private(set) var isLoading = false
    private(set) var isPublishing = false
    private(set) var hasLoadedOnce = false
    var errorMessage: String?
    private(set) var likedPostIDs: Set<UUID>
    private(set) var publishedRecordIDs: Set<UUID>

    var author: String {
        didSet { UserDefaults.standard.set(author, forKey: "MiniVid.feedAuthor") }
    }

    init() {
        let storedAuthor = UserDefaults.standard.string(forKey: "MiniVid.feedAuthor")
        let initialAuthor = storedAuthor ?? "dreamer-\(Int.random(in: 1000...9999))"
        author = initialAuthor
        likedPostIDs = Set(
            (UserDefaults.standard.array(forKey: "MiniVid.likedPosts") as? [String] ?? [])
                .compactMap(UUID.init)
        )
        publishedRecordIDs = Set(
            (UserDefaults.standard.array(forKey: "MiniVid.publishedRecords") as? [String] ?? [])
                .compactMap(UUID.init)
        )
        if storedAuthor == nil {
            UserDefaults.standard.set(initialAuthor, forKey: "MiniVid.feedAuthor")
        }
    }

    /// The configured backend, or an error naming what is missing.
    private static func endpoint() throws -> URL {
        guard let baseURL else { throw FeedError.notConfigured }
        return baseURL
    }

    func publicURL(for path: String) -> URL? {
        Self.baseURL?.appending(path: "storage/v1/object/public/minivid/\(path)")
    }

    // MARK: - Read

    func refresh() async {
        if isLoading { return }
        guard let base = Self.baseURL else { errorMessage = feedNotConfiguredMessage; return }
        isLoading = true
        errorMessage = nil
        do {
            let url = base
                .appending(path: "rest/v1/minivid_posts")
                .appending(queryItems: [
                    URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                    URLQueryItem(name: "limit", value: "50"),
                ])
            var request = URLRequest(url: url)
            authorize(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkOK(response, data: data)
            posts = try Self.decoder.decode([FeedPost].self, from: data)
            hasLoadedOnce = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Publish

    func isPublished(_ recordID: UUID) -> Bool {
        publishedRecordIDs.contains(recordID)
    }

    /// Uploads the video + thumbnail then inserts the post row.
    func publish(record: ProjectRecord, videoURL: URL, thumbURL: URL) async -> Bool {
        guard !isPublishing else { return false }
        guard Self.baseURL != nil else { errorMessage = feedNotConfiguredMessage; return false }
        isPublishing = true
        errorMessage = nil
        defer { isPublishing = false }

        do {
            let videoData = try Data(contentsOf: videoURL)
            guard videoData.count < 25_000_000 else { throw FeedError.videoTooLarge }
            let thumbData = try Data(contentsOf: thumbURL)

            let key = record.id.uuidString.lowercased()
            let videoPath = "videos/\(key).mp4"
            let thumbPath = "thumbs/\(key).png"
            try await upload(videoData, to: videoPath, contentType: "video/mp4")
            try await upload(thumbData, to: thumbPath, contentType: "image/png")

            var request = URLRequest(url: try Self.endpoint().appending(path: "rest/v1/minivid_posts"))
            request.httpMethod = "POST"
            authorize(&request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            let handle = author.trimmingCharacters(in: .whitespacesAndNewlines)
            let body: [String: Any] = [
                "author": handle.isEmpty ? "anonymous" : String(handle.prefix(40)),
                "prompt": String(record.config.prompt.prefix(500)),
                "video_path": videoPath,
                "thumb_path": thumbPath,
                "duration_seconds": record.config.durationSeconds,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkOK(response, data: data)

            publishedRecordIDs.insert(record.id)
            UserDefaults.standard.set(publishedRecordIDs.map(\.uuidString), forKey: "MiniVid.publishedRecords")
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Likes

    func hasLiked(_ post: FeedPost) -> Bool {
        likedPostIDs.contains(post.id)
    }

    func like(_ post: FeedPost) async {
        guard !likedPostIDs.contains(post.id) else { return }
        likedPostIDs.insert(post.id)
        UserDefaults.standard.set(likedPostIDs.map(\.uuidString), forKey: "MiniVid.likedPosts")
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts[index].likes += 1
        }

        guard let likeURL = Self.baseURL?.appending(path: "rest/v1/rpc/minivid_like") else { return }
        var request = URLRequest(url: likeURL)
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["post_id": post.id.uuidString])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Plumbing

    private func authorize(_ request: inout URLRequest) {
        guard let key = Self.anonKey else { return }
        request.setValue(key, forHTTPHeaderField: "apikey")
        // Two key formats are in circulation. A legacy anon key is a JWT and is
        // also expected as a bearer token; a publishable key (sb_publishable_...)
        // is not a JWT and must not be sent as one, or the request is rejected.
        if key.hasPrefix("eyJ") {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func upload(_ data: Data, to path: String, contentType: String) async throws {
        var request = URLRequest(url: try Self.endpoint().appending(path: "storage/v1/object/minivid/\(path)"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        try Self.checkOK(response, data: body)
    }

    private static func checkOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedError.server(http.statusCode, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// Supabase timestamps carry 6-digit fractional seconds, which
    /// ISO8601DateFormatter cannot parse — decode with explicit formats.
    private static let decoder: JSONDecoder = {
        let fractional = DateFormatter()
        fractional.locale = Locale(identifier: "en_US_POSIX")
        fractional.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx"
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: string) ?? plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable date: \(string)"
            ))
        }
        return decoder
    }()
}
