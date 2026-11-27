import Combine
import Foundation
import NeedleCore
import SwiftUI
@preconcurrency import WebKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@main
struct NeedleApp: App {
    @StateObject private var player = PlayerStore()
    #if os(macOS)
    @StateObject private var account = YouTubeAccount()
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(player)
            #if os(macOS)
                .environmentObject(account)
                .task { await account.refreshLibrary() }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 520, height: 900)
        #endif
    }
}

@MainActor
final class PlayerStore: ObservableObject {
    private static let lastPlaylistKey = "lastYouTubePlaylistURL"
    private static let savedPlaylistsKey = "savedYouTubePlaylists"

    struct SavedPlaylist: Codable, Equatable {
        let playlistID: String
        let title: String

        var url: String { "https://www.youtube.com/playlist?list=\(playlistID)" }
    }

    enum RepeatMode: String, CaseIterable {
        case off
        case one
        case all

        var label: String {
            switch self {
            case .off: "반복 끔"
            case .one: "한 곡 반복"
            case .all: "전곡 반복"
            }
        }

        var icon: String { self == .one ? "repeat.1" : "repeat" }
    }

    struct Command: Equatable {
        let id = UUID()
        let script: String
    }

    @Published var source: YouTubeSource?
    @Published var loadID = UUID()
    @Published var ready = false
    @Published var track = Track()
    @Published var isPlaying = false
    @Published var status = "READY"
    @Published var currentVideoID: String?
    @Published var qualityLabel: String?
    @Published var playlistIDs: [String] = []
    @Published var playlistIndex = 0
    @Published var error: Int?
    @Published var command: Command?
    @Published var channelArtworkURL: URL?
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    @Published var playlistTitle: String?
    @Published var savedPlaylists: [SavedPlaylist?] = Array(repeating: nil, count: 4)
    private var artworkVideoID: String?
    private var seekUntil = Date.distantPast

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedPlaylistsKey),
           let decoded = try? JSONDecoder().decode([SavedPlaylist?].self, from: data) {
            savedPlaylists = Array(decoded.prefix(4))
            savedPlaylists += Array(repeating: nil, count: 4 - savedPlaylists.count)
        }
        if let saved = UserDefaults.standard.string(forKey: Self.lastPlaylistKey) {
            _ = load(saved)
        }
    }

    var savedPlaylistURL: String {
        UserDefaults.standard.string(forKey: Self.lastPlaylistKey) ?? ""
    }

    var restoredInputText: String {
        displayText(for: savedPlaylistURL)
    }

    var isPlaylist: Bool {
        if case .playlist = source { return true }
        return false
    }

    var playlistLabel: String? {
        guard isPlaylist else { return nil }
        let count = playlistIDs.count
        return count > 0 ? "PLAYLIST  \(playlistIndex + 1) / \(count)" : "PLAYLIST LOADING"
    }

    var externalURL: URL? {
        if let id = currentVideoID {
            return URL(string: "https://youtu.be/\(id)")
        }
        if case .playlist(let id) = source {
            return URL(string: "https://www.youtube.com/playlist?list=\(id)")
        }
        return nil
    }

    @discardableResult
    func load(_ input: String) -> Bool {
        guard let parsed = YouTubeURL.source(from: input) else {
            status = "INVALID LINK"
            return false
        }
        source = parsed
        loadID = UUID()
        ready = false
        seekUntil = .distantPast
        track = Track(title: parsedTitle(parsed), artist: "YouTube")
        currentVideoID = videoID(from: parsed)
        qualityLabel = nil
        channelArtworkURL = nil
        artworkVideoID = nil
        playlistIDs = []
        playlistIndex = 0
        playlistTitle = nil
        isPlaying = false
        error = nil
        command = nil
        repeatMode = .off
        isShuffled = false
        status = "LOADING"
        if case .playlist(let id) = parsed {
            UserDefaults.standard.set(
                "https://www.youtube.com/playlist?list=\(id)",
                forKey: Self.lastPlaylistKey
            )
            Task { await loadPlaylistTitle(for: id) }
        }
        return true
    }

    func update(_ payload: [String: Any]) {
        guard payload["session"] as? String == loadID.uuidString else { return }
        if let quality = payload["quality"] as? String { qualityLabel = quality.isEmpty ? nil : quality }
        if let code = payload["error"] as? Int {
            error = code
            isPlaying = false
            status = [101, 150].contains(code) ? "EMBEDDING DISABLED" : "YOUTUBE ERROR \(code)"
            return
        }
        ready = payload["ready"] as? Bool ?? ready
        if let mode = payload["repeat"] as? String, let value = RepeatMode(rawValue: mode) { repeatMode = value }
        isShuffled = payload["shuffled"] as? Bool ?? isShuffled
        let state = payload["state"] as? Int ?? -1
        let current = payload["current"] as? Double ?? 0
        let duration = payload["duration"] as? Double ?? 0
        let title = payload["title"] as? String ?? "YouTube"
        let artist = payload["artist"] as? String ?? "YouTube"
        let videoID = payload["videoID"] as? String
        if let videoID, !videoID.isEmpty {
            currentVideoID = videoID
            if artworkVideoID != videoID {
                artworkVideoID = videoID
                Task { await loadChannelArtwork(for: videoID) }
            }
        }
        if let ids = payload["playlist"] as? [String] { playlistIDs = ids }
        playlistIndex = payload["index"] as? Int ?? playlistIndex

        track = Track(
            title: title.isEmpty ? "YouTube" : title,
            artist: artist,
            artworkURL: currentVideoID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/maxresdefault.jpg") },
            duration: duration,
            position: Date() < seekUntil ? min(track.position, duration) : current
        )
        isPlaying = state == 1
        error = nil
        status = switch state {
        case 1: "PLAYING"
        case 2: "PAUSED"
        case 3: "BUFFERING"
        default: "YOUTUBE READY"
        }
    }

    func togglePlayback() {
        send("needle.play()")
    }

    func previous() {
        seekUntil = .distantPast
        send("needle.step(-1)")
    }

    func next() {
        seekUntil = .distantPast
        send("needle.step(1)")
    }

    func play(at index: Int) {
        guard playlistIDs.indices.contains(index) else { return }
        seekUntil = .distantPast
        send("needle.select(\(index))")
    }

    func seek(to seconds: Double) {
        guard ready, seconds.isFinite, track.duration > 0 else { return }
        let target = min(max(seconds, 0), track.duration)
        track.position = target
        seekUntil = Date().addingTimeInterval(0.8)
        send("needle.seek(\(target))")
    }

    func movePlaylist(item: String, onto target: String) {
        guard let from = playlistIDs.firstIndex(of: item), let to = playlistIDs.firstIndex(of: target) else { return }
        send("needle.move(\(from),\(to))")
    }

    func cycleRepeat() {
        guard ready else { return }
        let modes = RepeatMode.allCases
        repeatMode = modes[(modes.firstIndex(of: repeatMode)! + 1) % modes.count]
        send("needle.repeat('\(repeatMode.rawValue)')")
    }

    func toggleShuffle() {
        guard ready, playlistIDs.count > 1 else { return }
        isShuffled.toggle()
        send("needle.shuffle(\(isShuffled ? "true" : "false"))")
    }

    @discardableResult
    func saveCurrentPlaylist(to slot: Int) -> String? {
        guard savedPlaylists.indices.contains(slot), case .playlist(let id) = source else { return nil }
        let title = playlistTitle ?? "YouTube 재생목록"
        savedPlaylists[slot] = SavedPlaylist(playlistID: id, title: title)
        persistSavedPlaylists()
        return savedPlaylistLabel(at: slot)
    }

    @discardableResult
    func loadSavedPlaylist(at slot: Int) -> String? {
        guard savedPlaylists.indices.contains(slot), let saved = savedPlaylists[slot] else { return nil }
        _ = load(saved.url)
        return savedPlaylistLabel(at: slot)
    }

    func loadInput(_ input: String) -> Bool {
        if let slot = savedPlaylists.indices.first(where: { savedPlaylistLabel(at: $0) == input }),
           let saved = savedPlaylists[slot] {
            return load(saved.url)
        }
        return load(input)
    }

    func savedPlaylistLabel(at slot: Int) -> String? {
        guard savedPlaylists.indices.contains(slot), let saved = savedPlaylists[slot] else { return nil }
        return "playlist\(slot + 1): \(saved.title)"
    }

    func removeSavedPlaylist(at slot: Int) {
        guard savedPlaylists.indices.contains(slot) else { return }
        savedPlaylists[slot] = nil
        persistSavedPlaylists()
    }

    private func send(_ script: String) {
        guard source != nil, ready else { return }
        command = Command(script: "if(window.needle){\(script)}")
    }

    private func persistSavedPlaylists() {
        guard let data = try? JSONEncoder().encode(savedPlaylists) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedPlaylistsKey)
    }

    private func displayText(for url: String) -> String {
        guard let slot = savedPlaylists.indices.first(where: { savedPlaylists[$0]?.url == url }) else { return url }
        return savedPlaylistLabel(at: slot) ?? url
    }

    private func parsedTitle(_ source: YouTubeSource) -> String {
        if case .playlist = source { return "재생목록 불러오는 중…" }
        return "영상 불러오는 중…"
    }

    private func videoID(from source: YouTubeSource) -> String? {
        if case .video(let id) = source { return id }
        return nil
    }

    private func loadPlaylistTitle(for playlistID: String) async {
        do {
            var components = URLComponents(string: "https://www.youtube.com/playlist")!
            components.queryItems = [URLQueryItem(name: "list", value: playlistID)]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8),
                  let title = YouTubeMetadata.playlistTitle(from: html),
                  case .playlist(let activeID) = source, activeID == playlistID else { return }
            playlistTitle = title

            var changed = false
            for slot in savedPlaylists.indices where savedPlaylists[slot]?.playlistID == playlistID {
                savedPlaylists[slot] = SavedPlaylist(playlistID: playlistID, title: title)
                changed = true
            }
            if changed { persistSavedPlaylists() }
        } catch {
            return
        }
    }

    private func loadChannelArtwork(for videoID: String) async {
        do {
            var components = URLComponents(string: "https://www.youtube.com/oembed")!
            components.queryItems = [
                URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
                URLQueryItem(name: "format", value: "json")
            ]
            let (oembedData, _) = try await URLSession.shared.data(from: components.url!)
            guard let object = try JSONSerialization.jsonObject(with: oembedData) as? [String: Any],
                  let authorURL = object["author_url"] as? String,
                  let url = URL(string: authorURL) else { return }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (pageData, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: pageData, encoding: .utf8) else { return }
            let patterns = [
                #"property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)"#,
                #"content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image[\"']"#
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let range = Range(match.range(at: 1), in: html) else { continue }
                let value = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
                if currentVideoID == videoID { channelArtworkURL = URL(string: value) }
                return
            }
        } catch {
            return
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var player: PlayerStore
    #if os(macOS)
    @EnvironmentObject private var account: YouTubeAccount
    @State private var showingAccount = false
    #endif
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @State private var input = ""
    @State private var videoOnly = false
    @State private var queueScrollIndex = 0

    private let accent = Color(red: 0.66, green: 0.59, blue: 1.00)

    var body: some View {
        ZStack {
            background
            if let source = player.source {
                YouTubePlayerView(source: source, player: player)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                if !videoOnly { videoScrim }
            }

            if videoOnly {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: toggleVideoOnly) {
                            Image(systemName: "arrow.down.left.and.arrow.up.right")
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.46), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("플레이어로 돌아가기")
                    }
                    Spacer()
                }
                .padding(24)
            } else {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 8)
                    turntableHero
                    Spacer(minLength: 8)
                    playerOverlay
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 760)
        .background(WindowConfigurationView(alwaysOnTop: alwaysOnTop))
        #else
        .frame(minHeight: 600)
        #endif
        .onAppear {
            if input.isEmpty { input = player.restoredInputText }
        }
        #if os(macOS)
        .sheet(isPresented: $showingAccount) {
            YouTubeAccountView(account: account, select: selectLibraryPlaylist)
        }
        #endif
        .onChange(of: player.savedPlaylists) {
            guard let slot = player.savedPlaylists.indices.first(where: {
                input.lowercased().hasPrefix("playlist\($0 + 1):")
            }) else { return }
            input = player.savedPlaylistLabel(at: slot) ?? player.savedPlaylistURL
        }
        .foregroundStyle(.white)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.025, green: 0.025, blue: 0.035)
            RadialGradient(
                colors: [accent.opacity(0.30), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }

    private var videoScrim: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.black.opacity(0.42), .clear, .black.opacity(0.24)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.10))
                    Capsule().fill(accent).frame(width: 2, height: 18).rotationEffect(.degrees(34))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("NEEDLE")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(3.2)
                    HStack(spacing: 6) {
                        Circle().fill(player.isPlaying ? .green : accent).frame(width: 5, height: 5)
                        Text(player.status)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1)
                        if let quality = player.qualityLabel {
                            Text(quality).font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if let label = player.playlistLabel {
                Label(label, systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(.black.opacity(0.34), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.10)))
            }

            #if os(macOS)
            Button {
                showingAccount = true
                Task { await account.refreshLibrary() }
            } label: {
                Image(systemName: account.signedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(account.signedIn ? accent : .white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("YouTube 로그인 및 내 재생목록")
            .accessibilityLabel("YouTube 계정")
            Toggle(isOn: $alwaysOnTop) {
                Image(systemName: "pin.fill").frame(width: 32, height: 32)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .background(alwaysOnTop ? accent.opacity(0.24) : .black.opacity(0.34), in: Circle())
            .foregroundStyle(alwaysOnTop ? accent : .secondary)
            .help("항상 위에 표시")
            #endif
        }
        .padding(.horizontal, 20)
        .frame(height: 72)
    }

    private var turntableHero: some View {
        VStack(spacing: 10) {
            TurntableView(track: player.track, channelArtworkURL: player.channelArtworkURL, isPlaying: player.isPlaying, accent: accent)
                .frame(width: 200, height: 200)
                .accessibilityLabel("\(player.track.title), \(player.track.artist)")

            Text(player.playlistLabel ?? "NOW PLAYING")
                .font(.system(size: 9, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(accent)

            Text(player.track.title)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.8)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 430)

            Text(player.track.artist.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .allowsHitTesting(true)
    }

    private var playerOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let code = player.error {
                Label(
                    [101, 150].contains(code) ? "이 영상은 앱 내 재생을 허용하지 않습니다" : "YouTube 오류 \(code)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                SeekBar(position: player.track.position, duration: player.track.duration,
                        accent: accent, seek: player.seek)
                    .disabled(!player.ready || player.track.duration <= 0)
                HStack {
                    Text(time(player.track.position))
                    Spacer()
                    Text("−" + time(max(0, player.track.duration - player.track.position)))
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                controlButton(player.isPlaylist ? "backward.end.fill" : "gobackward.10", action: player.previous)
                Button(action: player.togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(accent, in: Circle())
                        .foregroundStyle(Color(red: 0.06, green: 0.05, blue: 0.09))
                        .shadow(color: accent.opacity(0.42), radius: 18)
                }
                .buttonStyle(.plain)
                .disabled(!player.ready)
                .accessibilityLabel(player.isPlaying ? "일시정지" : "재생")
                controlButton(player.isPlaylist ? "forward.end.fill" : "goforward.10", action: player.next)
                Divider().frame(height: 24).overlay(.white.opacity(0.12)).padding(.horizontal, 2)
                modeButton(player.repeatMode.icon, isActive: player.repeatMode != .off, help: player.repeatMode.label, action: player.cycleRepeat)
                    .disabled(!player.ready)
                modeButton("shuffle", isActive: player.isShuffled, help: player.isShuffled ? "무작위 재생 켬" : "무작위 재생 끔", action: player.toggleShuffle)
                    .disabled(!player.ready || player.playlistIDs.count < 2)
                Spacer()
                Button(action: toggleVideoOnly) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.09), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("영상만 전체 화면")
            }

            if player.playlistIDs.count > 1 { playlistQueue }
            #if os(macOS)
            if account.signedIn {
                YouTubeLibraryPicker(account: account, source: player.source, select: selectLibraryPlaylist)
            }
            #endif
            linkField
        }
        .padding(18)
        .frame(maxWidth: 490)
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.10)))
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    #if os(macOS)
    private func selectLibraryPlaylist(_ playlist: YouTubeLibraryPlaylist) {
        guard player.source != .playlist(playlist.id) else { return }
        if player.load(playlist.url) { input = playlist.url }
    }
    #endif

    private var playlistQueue: some View {
        VStack(spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PLAYLIST QUEUE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(2.1)
                        .foregroundStyle(accent)
                    Text("\(player.playlistIndex + 1)번째 재생 중 · \(max(0, player.playlistIDs.count - player.playlistIndex - 1))개 남음")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView(value: Double(player.playlistIndex + 1), total: Double(player.playlistIDs.count))
                    .tint(accent)
                    .frame(width: 80)
            }

            Label("드래그로 순서 변경 · 좌우 스크롤", systemImage: "hand.draw")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)

            ScrollViewReader { proxy in
                HStack(spacing: 8) {
                    queueArrow("chevron.left", disabled: queueScrollIndex == 0) {
                        scrollQueue(proxy, to: 0)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 9) {
                            ForEach(Array(player.playlistIDs.enumerated()), id: \.offset) { index, id in
                                Button { player.play(at: index) } label: {
                                    AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")) { phase in
                                        if let image = phase.image {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Color.white.opacity(0.06)
                                        }
                                    }
                                    .frame(width: 104, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(alignment: .bottom) {
                                        LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom)
                                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    }
                                    .overlay(alignment: .bottomLeading) {
                                        HStack(spacing: 5) {
                                            if index == player.playlistIndex {
                                                Image(systemName: player.isPlaying ? "waveform" : "play.fill")
                                                    .foregroundStyle(accent)
                                            } else if index < player.playlistIndex {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.white.opacity(0.55))
                                            }
                                            Text(String(format: "%02d", index + 1))
                                            Text("/ \(player.playlistIDs.count)")
                                                .foregroundStyle(.white.opacity(0.55))
                                        }
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(7)
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(index == player.playlistIndex ? accent : .white.opacity(0.12), lineWidth: index == player.playlistIndex ? 2 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                                .draggable(id)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let dragged = items.first else { return false }
                                    player.movePlaylist(item: dragged, onto: id)
                                    queueScrollIndex = player.currentVideoID.flatMap { player.playlistIDs.firstIndex(of: $0) } ?? 0
                                    return true
                                }
                                .help("\(index + 1)번 · 클릭하여 재생 · 드래그하여 순서 변경")
                                .accessibilityLabel("재생목록 \(index + 1)번 영상")
                            }
                        }
                    }
                    .frame(height: 62)
                    .onChange(of: player.playlistIndex) { _, index in
                        queueScrollIndex = index
                        guard player.playlistIDs.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }

                    queueArrow("chevron.right", disabled: queueScrollIndex >= player.playlistIDs.count - 1) {
                        scrollQueue(proxy, to: player.playlistIDs.count - 1)
                    }
                }
            }
        }
    }

    private func queueArrow(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 27, height: 60)
                .background(.white.opacity(disabled ? 0.025 : 0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.35) : Color.white.opacity(0.82))
        .disabled(disabled)
    }

    private func scrollQueue(_ proxy: ScrollViewProxy, to requestedIndex: Int) {
        let index = min(max(0, requestedIndex), player.playlistIDs.count - 1)
        queueScrollIndex = index
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private var linkField: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("YouTube 영상 또는 재생목록 링크", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { _ = player.loadInput(input) }
            savedPlaylistsMenu
            Button { _ = player.loadInput(input) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.11), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .frame(height: 42)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.09)))
    }

    private var savedPlaylistsMenu: some View {
        Menu {
            Section("현재 재생목록 저장") {
                ForEach(0..<4, id: \.self) { slot in
                    Button {
                        if let label = player.saveCurrentPlaylist(to: slot) { input = label }
                    } label: {
                        Label(
                            "playlist\(slot + 1) \(player.savedPlaylists[slot] == nil ? "저장" : "덮어쓰기")",
                            systemImage: "bookmark.badge.plus"
                        )
                    }
                    .disabled(!player.isPlaylist)
                }
            }

            Section("저장된 재생목록") {
                ForEach(0..<4, id: \.self) { slot in
                    if let label = player.savedPlaylistLabel(at: slot) {
                        Button {
                            if let loadedLabel = player.loadSavedPlaylist(at: slot) { input = loadedLabel }
                        } label: {
                            Label(label, systemImage: "play.fill")
                        }
                    } else {
                        Text("playlist\(slot + 1): 비어 있음")
                    }
                }
            }

            if player.savedPlaylists.contains(where: { $0 != nil }) {
                Section("저장 목록 삭제") {
                    ForEach(0..<4, id: \.self) { slot in
                        if let label = player.savedPlaylistLabel(at: slot) {
                            Button("playlist\(slot + 1) 삭제", role: .destructive) {
                                player.removeSavedPlaylist(at: slot)
                                if input == label { input = player.savedPlaylistURL }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: player.savedPlaylists.contains(where: { $0 != nil }) ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("재생목록 4개 저장 및 불러오기")
    }

    private func controlButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.09), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(!player.ready)
    }

    private func modeButton(_ icon: String, isActive: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(isActive ? accent.opacity(0.24) : .white.opacity(0.07), in: Circle())
                .foregroundStyle(isActive ? accent : .white.opacity(0.72))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func toggleVideoOnly() {
        #if os(macOS)
        let window = NSApp.keyWindow
        if videoOnly {
            videoOnly = false
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        } else {
            videoOnly = true
            if window?.styleMask.contains(.fullScreen) == false { window?.toggleFullScreen(nil) }
        }
        #else
        videoOnly.toggle()
        #endif
    }

    private func time(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = max(0, Int(value))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct SeekBar: View {
    let position: Double
    let duration: Double
    let accent: Color
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @State private var lastSeek = Date.distantPast

    var body: some View {
        GeometryReader { geometry in
            let fraction = duration > 0 ? min(max((dragging ?? position) / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16)).frame(height: 4)
                Capsule().fill(accent).frame(width: geometry.size.width * fraction, height: 4)
                Circle().fill(.white).frame(width: dragging == nil ? 8 : 12, height: dragging == nil ? 8 : 12)
                    .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * fraction - 6)))
            }
            .frame(height: 24).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard duration > 0, geometry.size.width > 0 else { return }
                    let target = min(max(value.location.x / geometry.size.width, 0), 1) * duration
                    dragging = target
                    if Date().timeIntervalSince(lastSeek) >= 0.1 {
                        lastSeek = Date(); seek(target)
                    }
                }
                .onEnded { value in
                    if duration > 0, geometry.size.width > 0 {
                        seek(min(max(value.location.x / geometry.size.width, 0), 1) * duration)
                    }
                    dragging = nil
                })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("재생 위치")
        .accessibilityValue("\(Int(dragging ?? position))초 / \(Int(duration))초")
        .accessibilityAdjustableAction { direction in
            seek(min(max(position + (direction == .increment ? 5 : -5), 0), duration))
        }
    }
}

struct TurntableView: View {
    let track: Track
    let channelArtworkURL: URL?
    let isPlaying: Bool
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { context in
            ZStack {
                ZStack {
                    Circle()
                        .fill(AngularGradient(
                            colors: [.black, Color(white: 0.20), .black, Color(white: 0.10), .black],
                            center: .center
                        ))
                    ForEach(1..<13) { ring in
                        Circle()
                            .stroke(.white.opacity(ring.isMultiple(of: 3) ? 0.11 : 0.035), lineWidth: 1)
                            .padding(CGFloat(ring * 7))
                    }
                    Circle().fill(.black).frame(width: 8, height: 8)
                }
                .rotationEffect(.degrees(isPlaying ? context.date.timeIntervalSinceReferenceDate * 42 : 0))
                .shadow(color: .black.opacity(0.82), radius: 30, y: 16)

                channelArtwork
                    .frame(width: 94, height: 94)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.20)))
                    .shadow(color: .black.opacity(0.45), radius: 8)

                VStack(spacing: -3) {
                    Circle()
                        .fill(Color(white: 0.25).gradient)
                        .overlay(Circle().stroke(.white.opacity(0.18)))
                        .frame(width: 27, height: 27)
                    Capsule()
                        .fill(.linearGradient(
                            colors: [Color(white: 0.62), Color(white: 0.22), Color(white: 0.68)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: 7, height: 118)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accent)
                        .frame(width: 18, height: 9)
                }
                .rotationEffect(.degrees(18 + track.progress * 18), anchor: .top)
                .offset(x: 98, y: -54)
                .animation(.easeInOut(duration: 0.8), value: track.progress)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var channelArtwork: some View {
        if let url = channelArtworkURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    channelPlaceholder
                }
            }
        } else {
            channelPlaceholder
        }
    }

    private var channelPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.18, blue: 0.34), accent], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

@MainActor
final class YouTubeCoordinator: NSObject, WKScriptMessageHandler {
    let player: PlayerStore
    var loadedSource = ""
    var lastCommandID: UUID?

    init(player: PlayerStore) { self.player = player }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let payload = message.body as? [String: Any] else { return }
        player.update(payload)
    }
}

#if os(macOS)
struct YouTubePlayerView: NSViewRepresentable {
    let source: YouTubeSource
    @ObservedObject var player: PlayerStore

    func makeCoordinator() -> YouTubeCoordinator { YouTubeCoordinator(player: player) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "playback")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) { update(view, context: context) }

    private func update(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedSource != player.loadID.uuidString {
            context.coordinator.loadedSource = player.loadID.uuidString
            view.loadHTMLString(youtubeHTML(source, session: player.loadID), baseURL: youtubeIdentityURL)
        }
        if let command = player.command, context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            view.evaluateJavaScript(command.script)
        }
    }
}

struct WindowConfigurationView: NSViewRepresentable {
    let alwaysOnTop: Bool
    func makeNSView(context: Context) -> WindowConfigurationNSView { WindowConfigurationNSView(alwaysOnTop: alwaysOnTop) }
    func updateNSView(_ view: WindowConfigurationNSView, context: Context) {
        view.alwaysOnTop = alwaysOnTop
        view.configure()
    }
}

final class WindowConfigurationNSView: NSView {
    var alwaysOnTop: Bool
    init(alwaysOnTop: Bool) {
        self.alwaysOnTop = alwaysOnTop
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { configure() }
    func configure() {
        guard let window else { return }
        window.level = alwaysOnTop ? .floating : .normal
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }
}
#elseif os(iOS)
struct YouTubePlayerView: UIViewRepresentable {
    let source: YouTubeSource
    @ObservedObject var player: PlayerStore

    func makeCoordinator() -> YouTubeCoordinator { YouTubeCoordinator(player: player) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "playback")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loadedSource != player.loadID.uuidString {
            context.coordinator.loadedSource = player.loadID.uuidString
            view.loadHTMLString(youtubeHTML(source, session: player.loadID), baseURL: youtubeIdentityURL)
        }
        if let command = player.command, context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            view.evaluateJavaScript(command.script)
        }
    }
}
#endif

private let youtubeIdentityURL = URL(string: "https://app.codex.needle/")!

private func youtubeHTML(_ source: YouTubeSource, session: UUID) -> String {
    var configuration = ["session": session.uuidString]
    switch source {
    case .video(let id):
        configuration["videoID"] = id
    case .playlist(let id):
        configuration["playlistID"] = id
    }
    let json = String(data: try! JSONSerialization.data(withJSONObject: configuration), encoding: .utf8)!
    let resources = Bundle.main.url(forResource: "Needle_Needle", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? Bundle.module
    let script = try! String(contentsOf: resources.url(forResource: "Player", withExtension: "js")!, encoding: .utf8)

    return """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="referrer" content="strict-origin-when-cross-origin">
    <style>
    html,body{width:100%;height:100%;margin:0;background:#07070a;overflow:hidden}
    #player{position:absolute;left:50%;top:50%;width:var(--video-width);height:var(--video-height);transform:translate(-50%,-50%) scale(var(--video-scale));border:0;pointer-events:none}
    #sync-probe{position:absolute;width:200px;height:200px;opacity:0;pointer-events:none;overflow:hidden}
    </style></head><body><div id="player"></div><div id="sync-probe"></div>
    <script>
    function sizeVideo() {
      const coverWidth = Math.max(innerWidth, innerHeight * 16 / 9, 1);
      const width = Math.max(3840, coverWidth);
      const style = document.documentElement.style;
      style.setProperty('--video-width', width + 'px');
      style.setProperty('--video-height', width * 9 / 16 + 'px');
      style.setProperty('--video-scale', coverWidth / width);
    }
    sizeVideo();
    addEventListener('resize', sizeVideo);
    window.needleConfig=\(json);</script>
    <script>\(script)</script>
    <script src="https://www.youtube.com/iframe_api"></script></body></html>
    """
}
