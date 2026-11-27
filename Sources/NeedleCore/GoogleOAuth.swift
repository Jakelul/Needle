import Foundation
import CryptoKit

public struct GoogleDesktopClient: Codable, Sendable {
    public let client_id: String
    public let client_secret: String?

    public static func read(_ data: Data) throws -> Self {
        guard data.count < 64_000 else { throw OAuthFailure("OAuth 설정 파일이 너무 큽니다.") }
        struct Download: Decodable { let installed: GoogleDesktopClient }
        let client = try JSONDecoder().decode(Download.self, from: data).installed
        guard client.client_id.range(of: #"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,
                                     options: .regularExpression) != nil else {
            throw OAuthFailure("Google 데스크톱 앱의 OAuth JSON 파일을 선택해 주세요.")
        }
        return client
    }

    public static func select(bundled: Data?, imported: Data?) throws -> Self? {
        if let bundled { return try read(bundled) }
        if let imported { return try JSONDecoder().decode(Self.self, from: imported) }
        return nil
    }

    public func acceptsToken(issuedTo clientID: String?) -> Bool {
        clientID == client_id
    }
}

public struct OAuthFailure: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum GoogleOAuth {
    public static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    // Ignore unrelated or forged requests without consuming a pending login.
    public static func callback(_ request: String, state: String) -> Result<String, OAuthFailure>? {
        let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/oauth/callback?"),
              let url = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              url.path == "/oauth/callback" else { return nil }
        let items = url.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        let errors = items.filter { $0.name == "error" }
        guard states.count == 1, states[0].value == state else { return nil }
        if errors.count == 1 && codes.isEmpty {
            return .failure(OAuthFailure("Google 로그인을 취소했거나 접근 권한이 허용되지 않았습니다."))
        }
        guard errors.isEmpty, codes.count == 1, let code = codes[0].value, !code.isEmpty else { return nil }
        return .success(code)
    }
}

public struct YouTubeLibraryPlaylist: Decodable, Identifiable, Sendable {
    public let id: String
    public let snippet: Snippet
    public let contentDetails: Details
    public struct Snippet: Decodable, Sendable { public let title: String }
    public struct Details: Decodable, Sendable { public let itemCount: Int }
    public var url: String { "https://www.youtube.com/playlist?list=\(id)" }
}
