import Foundation

public enum YouTubeSource: Equatable, Sendable {
    case video(String)
    case playlist(String)

    public var key: String {
        switch self {
        case .video(let id): "video:\(id)"
        case .playlist(let id): "playlist:\(id)"
        }
    }
}

public struct Track: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var artworkURL: URL?
    public var duration: TimeInterval
    public var position: TimeInterval

    public init(
        title: String = "YouTube 링크를 붙여넣으세요",
        artist: String = "영상과 재생목록을 지원합니다",
        artworkURL: URL? = nil,
        duration: TimeInterval = 0,
        position: TimeInterval = 0
    ) {
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.position = position
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

public enum YouTubeURL {
    public static func source(from input: String) -> YouTubeSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isVideoID(trimmed) { return .video(trimmed) }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let host = components.host?.lowercased(),
              host == "youtu.be" || host.hasSuffix(".youtu.be") ||
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }

        if let list = components.queryItems?.first(where: { $0.name == "list" })?.value,
           isPlaylistID(list) {
            return .playlist(list)
        }

        let candidate: String?
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            candidate = components.path.split(separator: "/").first.map(String.init)
        } else {
            let parts = components.path.split(separator: "/").map(String.init)
            if components.path == "/watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if let marker = parts.firstIndex(where: { ["embed", "shorts", "live"].contains($0) }),
                      parts.indices.contains(marker + 1) {
                candidate = parts[marker + 1]
            } else {
                candidate = nil
            }
        }
        return candidate.flatMap { isVideoID($0) ? .video($0) : nil }
    }

    private static func isVideoID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    private static func isPlaylistID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{10,100}$"#, options: .regularExpression) != nil
    }
}

public enum YouTubeQueue {
    public static func moving(_ items: [String], item: String, onto target: String) -> [String] {
        guard item != target,
              let source = items.firstIndex(of: item),
              let destination = items.firstIndex(of: target) else { return items }
        var result = items
        let moved = result.remove(at: source)
        result.insert(moved, at: min(destination, result.count))
        return result
    }

    public static func syncedIndex(currentVideoID: String?, currentIndex: Int, updated: [String]) -> Int {
        guard !updated.isEmpty else { return 0 }
        return currentVideoID.flatMap { updated.firstIndex(of: $0) }
            ?? min(max(0, currentIndex), updated.count - 1)
    }
}

public enum YouTubeMetadata {
    public static func playlistTitle(from html: String) -> String? {
        let patterns = [
            #"(?:property|name)=[\"'](?:og:)?title[\"'][^>]+content=[\"']([^\"']+)"#,
            #"content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"'](?:og:)?title[\"']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }
}
