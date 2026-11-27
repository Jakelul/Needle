#if os(macOS)
import AppKit
import Combine
import Foundation
import NeedleCore
@preconcurrency import Network
import Security
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class YouTubeAccount: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var signedIn = false
    @Published private(set) var busy = false
    @Published private(set) var channelName = ""
    @Published private(set) var playlists: [YouTubeLibraryPlaylist] = []
    @Published var message: String?
    let hasBundledConfiguration: Bool
    private var client: GoogleDesktopClient?
    private var token: Token?
    private var generation = UUID()
    private var login: LoopbackLogin?
    private let session = URLSession(configuration: .ephemeral, delegate: NoOAuthRedirects(), delegateQueue: nil)

    private struct Token: Codable {
        let clientID: String?
        let access: String
        let refresh: String
        let expires: Date
    }
    private struct TokenReply: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let scope: String?
    }
    private struct PlaylistPage: Decodable {
        let items: [YouTubeLibraryPlaylist]
        let nextPageToken: String?
    }
    private struct ChannelPage: Decodable {
        struct Channel: Decodable {
            struct Snippet: Decodable { let title: String }
            let snippet: Snippet
        }
        let items: [Channel]
    }

    init() {
        let resources = Bundle.main.url(forResource: "Needle_Needle", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        let bundledURL = resources.url(forResource: "GoogleOAuth", withExtension: "json")
        hasBundledConfiguration = bundledURL != nil
        do {
            let bundled = try bundledURL.map { try Data(contentsOf: $0) }
            client = try GoogleDesktopClient.select(bundled: bundled,
                imported: bundled == nil ? AccountKeychain.read("google-client") : nil)
            configured = client != nil
            if let data = try AccountKeychain.read("google-token") {
                let saved = try JSONDecoder().decode(Token.self, from: data)
                if let client, client.acceptsToken(issuedTo: saved.clientID) {
                    token = saved; signedIn = true
                } else {
                    try AccountKeychain.remove("google-token")
                    message = "로그인 설정이 업데이트되었습니다. Google로 다시 로그인해 주세요."
                }
            }
        } catch { message = error.localizedDescription }
    }

    func importClient(_ url: URL) {
        guard !busy, !hasBundledConfiguration else { return }
        do {
            let allowed = url.startAccessingSecurityScopedResource()
            defer { if allowed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let imported = try GoogleDesktopClient.read(data)
            try AccountKeychain.remove("google-token")
            generation = UUID()
            token = nil; signedIn = false; playlists = []; channelName = ""
            try AccountKeychain.write(try JSONEncoder().encode(imported), account: "google-client")
            client = imported; configured = true; message = nil
        } catch { message = error.localizedDescription }
    }

    func signIn() async {
        guard let client, !busy else { return }
        busy = true; message = nil
        let current = generation
        defer { if current == generation { busy = false; login = nil } }
        do {
            let verifier = try Self.random()
            let callback = LoopbackLogin()
            login = callback
            let result = try await callback.authorize(clientID: client.client_id, verifier: verifier, state: Self.random())
            guard current == generation else { return }
            let reply = try await exchange([
                "grant_type":"authorization_code", "code":result.code,
                "redirect_uri":result.redirect, "code_verifier":verifier
            ], client: client, generation: current)
            guard current == generation else { return }
            try save(reply, previousRefresh: nil, clientID: client.client_id)
            signedIn = true
            try await fetchLibrary(generation: current)
        } catch {
            if current == generation { message = error.localizedDescription }
        }
    }

    func refreshLibrary() async {
        guard signedIn, !busy else { return }
        busy = true; message = nil
        let current = generation
        defer { if current == generation { busy = false } }
        do { try await fetchLibrary(generation: current) }
        catch { if current == generation { message = error.localizedDescription } }
    }

    func cancelLogin() {
        generation = UUID()
        login?.cancel()
        login = nil; busy = false
    }

    func signOut() {
        cancelLogin()
        do {
            try AccountKeychain.remove("google-token")
            token = nil; signedIn = false; playlists = []; channelName = ""; message = nil
        } catch { message = error.localizedDescription }
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OAuthFailure("안전한 로그인 요청을 만들 수 없습니다. 다시 시도해 주세요.")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func save(_ reply: TokenReply, previousRefresh: String?, clientID: String) throws {
        let scope = "https://www.googleapis.com/auth/youtube.readonly"
        if let scopes = reply.scope, !scopes.split(separator: " ").contains(Substring(scope)) {
            throw OAuthFailure("내 재생목록을 보려면 YouTube 읽기 권한을 허용해 주세요.")
        }
        guard let refresh = reply.refresh_token ?? previousRefresh, !refresh.isEmpty else {
            throw OAuthFailure("로그인 유지 권한을 받지 못했습니다. Google 계정에서 Needle 연결을 해제한 후 다시 로그인해 주세요.")
        }
        let saved = Token(clientID: clientID, access: reply.access_token, refresh: refresh,
                          expires: Date().addingTimeInterval(reply.expires_in))
        try AccountKeychain.write(try JSONEncoder().encode(saved), account: "google-token")
        token = saved
    }

    private func exchange(_ fields: [String:String], client: GoogleDesktopClient, generation current: UUID) async throws -> TokenReply {
        var body = fields
        body["client_id"] = client.client_id
        body["client_secret"] = client.client_secret
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.form(body)
        let (data, response) = try await session.data(for: request)
        guard current == generation else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            struct Failure: Decodable { let error: String }
            if (try? JSONDecoder().decode(Failure.self, from: data).error) == "invalid_grant" {
                try AccountKeychain.remove("google-token")
                token = nil; signedIn = false; playlists = []; channelName = ""
                throw OAuthFailure("Google 연결이 만료되었습니다. 다시 로그인해 주세요.")
            }
            throw OAuthFailure("Google 인증에 실패했습니다. 데스크톱 OAuth 설정과 테스트 사용자 등록을 확인해 주세요.")
        }
        return try JSONDecoder().decode(TokenReply.self, from: data)
    }

    private func accessToken(generation current: UUID) async throws -> String {
        guard let token, let client, client.acceptsToken(issuedTo: token.clientID) else {
            throw OAuthFailure("Google 로그인이 필요합니다.")
        }
        if token.expires > Date().addingTimeInterval(60) { return token.access }
        let refreshed = try await exchange(["grant_type":"refresh_token","refresh_token":token.refresh],
                                           client: client, generation: current)
        guard current == generation else { throw CancellationError() }
        try save(refreshed, previousRefresh: token.refresh, clientID: client.client_id)
        return refreshed.access_token
    }

    private func api<T: Decodable>(_ resource: String, query: [URLQueryItem], generation current: UUID, as type: T.Type) async throws -> T {
        let access = try await accessToken(generation: current)
        var url = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(resource)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard current == generation else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { throw OAuthFailure("계정 권한을 확인할 수 없습니다. 로그아웃 후 다시 로그인해 주세요.") }
            throw OAuthFailure(status == 403
                ? "YouTube 접근이 제한되었습니다. YouTube Data API 사용 설정, 계정 권한 또는 사용량을 확인해 주세요."
                : "재생목록을 가져오지 못했습니다 (\(status)). 잠시 후 다시 시도해 주세요.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchLibrary(generation current: UUID) async throws {
        let channel = try await api("channels", query:[
            .init(name:"part", value:"snippet"), .init(name:"mine", value:"true")
        ], generation: current, as: ChannelPage.self)
        var result: [YouTubeLibraryPlaylist] = []
        var next: String?
        var visited = Set<String>()
        repeat {
            var query = [URLQueryItem(name:"part",value:"snippet,contentDetails"),
                         .init(name:"mine",value:"true"), .init(name:"maxResults",value:"50")]
            if let next { query.append(.init(name:"pageToken",value:next)) }
            let page = try await api("playlists", query:query, generation:current, as:PlaylistPage.self)
            result += page.items.filter { YouTubeURL.source(from: $0.url) == .playlist($0.id) }
            next = page.nextPageToken
            if let next, !visited.insert(next).inserted { throw OAuthFailure("목록 응답이 반복되어 중단했습니다. 다시 새로고침해 주세요.") }
        } while next != nil
        guard current == generation else { return }
        channelName = channel.items.first?.snippet.title ?? "내 YouTube"
        playlists = result
    }
}

private final class NoOAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum AccountKeychain {
    static func query(_ account: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"app.codex.needle.google",
         kSecAttrAccount as String:account]
    }
    static func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return result as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let attributes: [String:Any] = [kSecValueData as String:data,
                                       kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(account).merging(attributes) { _,new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw OAuthFailure("macOS 키체인에 접근할 수 없습니다 (\(status)).") }
    }
}

@MainActor
private final class LoopbackLogin {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier:NWConnection] = [:]
    private var continuation: CheckedContinuation<(code:String,redirect:String), Error>?
    private var timeout: Task<Void,Never>?
    private var state = ""
    private var redirect = ""
    private var consumed = false

    func authorize(clientID: String, verifier: String, state: String) async throws -> (code:String,redirect:String) {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        let listener = try NWListener(using:parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection) }
            }
            listener.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.continuation != nil else { return }
                    switch status {
                    case .ready:
                        guard let port = self.listener?.port else { self.cancel(); return }
                        self.redirect = "http://127.0.0.1:\(port.rawValue)/oauth/callback"
                        var url = URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
                        url.queryItems = [
                            .init(name:"client_id",value:clientID), .init(name:"redirect_uri",value:self.redirect),
                            .init(name:"response_type",value:"code"), .init(name:"scope",value:"https://www.googleapis.com/auth/youtube.readonly"),
                            .init(name:"state",value:state), .init(name:"code_challenge",value:GoogleOAuth.challenge(verifier)),
                            .init(name:"code_challenge_method",value:"S256"), .init(name:"access_type",value:"offline"),
                            .init(name:"prompt",value:"consent select_account")
                        ]
                        if !NSWorkspace.shared.open(url.url!) { self.finish(.failure(OAuthFailure("브라우저를 열 수 없습니다."))) }
                    case .failed: self.finish(.failure(OAuthFailure("로그인 응답을 받을 수 없습니다. 다시 시도해 주세요.")))
                    default: break
                    }
                }
            }
            listener.start(queue:.main)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(180)) } catch { return }
                self?.finish(.failure(OAuthFailure("로그인 시간이 초과되었습니다. 다시 시도해 주세요.")))
            }
        }
    }

    func cancel() { finish(.failure(OAuthFailure("로그인을 취소했습니다."))) }

    private func receive(_ connection: NWConnection) {
        guard continuation != nil, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue:.main)
        read(connection, accumulated:Data())
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength:1, maximumLength:4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                let bytes = accumulated + (data ?? Data())
                guard bytes.count <= 16_384 else { self.close(connection); return }
                guard let request = String(data:bytes,encoding:.utf8) else { self.close(connection); return }
                if !request.contains("\r\n\r\n") {
                    if complete || error != nil { self.close(connection) }
                    else { self.read(connection,accumulated:bytes) }
                    return
                }
                let result = self.consumed ? nil : GoogleOAuth.callback(request,state:self.state)
                self.consumed = self.consumed || result != nil
                let body = result == nil ? "Invalid request." : "Return to Needle to finish connecting YouTube. You may close this tab."
                let response = "HTTP/1.1 \(result == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content:Data(response.utf8), completion:.contentProcessed { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.close(connection)
                        if let result { self.finish(result.map { (code:$0,redirect:self.redirect) }.mapError { $0 as Error }) }
                    }
                })
            }
        }
    }
    private func close(_ connection: NWConnection) {
        connection.cancel(); connections.removeValue(forKey:ObjectIdentifier(connection))
    }
    private func finish(_ result: Result<(code:String,redirect:String),Error>) {
        let pending = continuation
        continuation = nil
        listener?.cancel(); listener = nil
        timeout?.cancel(); timeout = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        pending?.resume(with:result)
    }
}

private struct YouTubePlaylistList: View {
    let playlists: [YouTubeLibraryPlaylist]
    var source: YouTubeSource? = nil
    let select: (YouTubeLibraryPlaylist) -> Void
    private let accent = Color(red: 0.66, green: 0.59, blue: 1.00)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(playlists) { playlist in
                    let selected = source == .playlist(playlist.id)
                    Button { select(playlist) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "music.note.list")
                                .foregroundStyle(accent)
                                .frame(width: 20)
                            Text(playlist.snippet.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text("\(playlist.contentDetails.itemCount)곡")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Image(systemName: "play.fill").font(.system(size: 10))
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? accent.opacity(0.18) : .white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 11))
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(playlist.contentDetails.itemCount == 0)
                    .accessibilityLabel("\(playlist.snippet.title), \(playlist.contentDetails.itemCount)곡")
                    .accessibilityValue(selected ? "현재 재생목록" : "")
                }
            }.padding(.trailing, 6)
        }
    }
}

struct YouTubeLibraryPicker: View {
    @ObservedObject var account: YouTubeAccount
    let source: YouTubeSource?
    let select: (YouTubeLibraryPlaylist) -> Void
    @State private var expanded = false
    private let accent = Color(red: 0.66, green: 0.59, blue: 1.00)

    private var selectedTitle: String? {
        account.playlists.first { source == .playlist($0.id) }?.snippet.title
    }

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").foregroundStyle(accent)
                Text(selectedTitle ?? "내 재생목록")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(account.playlists.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            }
            .padding(.horizontal, 13).frame(height: 38)
            .background(accent.opacity(expanded ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.18)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help("내 채널 재생목록 펼치기 / 접기")
        .accessibilityLabel("내 재생목록")
        .accessibilityValue(expanded ? "펼쳐짐" : "접힘")
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("내 재생목록").font(.system(size: 14, weight: .semibold))
                        Text("\(account.channelName) · \(account.playlists.count)개")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if account.busy { ProgressView().controlSize(.small) }
                    Button { Task { await account.refreshLibrary() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }.disabled(account.busy).help("재생목록 새로고침").accessibilityLabel("재생목록 새로고침")
                    Button { expanded = false } label: {
                        Image(systemName: "xmark").frame(width: 28, height: 28)
                    }.help("재생목록 접기").accessibilityLabel("재생목록 접기")
                }.buttonStyle(.plain)
                if let message = account.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if account.playlists.isEmpty {
                    Text(account.busy ? "재생목록 불러오는 중…" : "이 채널에서 만든 재생목록이 없습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    YouTubePlaylistList(playlists: account.playlists, source: source) { playlist in
                        select(playlist)
                        expanded = false
                    }.frame(height: 270)
                }
            }
            .padding(16).frame(width: 370)
            .preferredColorScheme(.dark)
            .onExitCommand { expanded = false }
            .task { await account.refreshLibrary() }
        }
    }
}

struct YouTubeAccountView: View {
    @ObservedObject var account: YouTubeAccount
    let select: (YouTubeLibraryPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Label(account.signedIn ? account.channelName : "YouTube 연결",systemImage:"person.crop.circle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }
            }
            if let message = account.message {
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if account.signedIn {
                HStack {
                    Text("내 채널 재생목록 · \(account.playlists.count)개").foregroundStyle(.secondary)
                    Spacer()
                    Button("새로고침") { Task { await account.refreshLibrary() } }.disabled(account.busy)
                    Button("로그아웃",role:.destructive) { account.signOut() }
                }
                if account.playlists.isEmpty && !account.busy {
                    Text("이 채널에서 만든 재생목록이 없습니다.").foregroundStyle(.secondary)
                }
                YouTubePlaylistList(playlists: account.playlists) { playlist in
                    select(playlist); dismiss()
                }
                Text("내 채널에서 만든 목록이 표시됩니다. 비공개 목록·영상은 YouTube 외부 재생이 제한될 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if account.configured {
                    Text("Google에서 로그인하면 내 채널의 재생목록을 자동으로 불러옵니다.")
                    Button("Google로 로그인") { Task { await account.signIn() } }
                        .buttonStyle(.borderedProminent).disabled(account.busy)
                    Text("YouTube 읽기 권한만 요청합니다. 계정 비밀번호는 Google 브라우저 화면에서 입력합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("이 빌드는 Google 로그인이 아직 설정되지 않았습니다. 연결 설정이 포함된 배포 버전이 필요합니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !account.hasBundledConfiguration {
                    DisclosureGroup("개발자 설정") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("직접 빌드하는 개발자는 Google Cloud에서 만든 데스크톱 OAuth JSON을 선택할 수 있습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            Link("Google Cloud 설정 열기",destination:URL(string:"https://console.cloud.google.com/auth/clients")!)
                            Button(account.configured ? "연결 설정 바꾸기…" : "OAuth 설정 파일 선택…") { importing = true }
                                .disabled(account.busy)
                        }.padding(.top, 8)
                    }
                }
                Spacer()
            }
            if account.busy {
                HStack { ProgressView().controlSize(.small); Text("연결 중…"); Spacer()
                    if !account.signedIn { Button("취소") { account.cancelLogin() } }
                }
            }
        }
        .padding(24).frame(width:430,height:510).preferredColorScheme(.dark)
        .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
            switch result {
            case .success(let url): account.importClient(url)
            case .failure(let error): account.message = error.localizedDescription
            }
        }
    }
}
#endif
