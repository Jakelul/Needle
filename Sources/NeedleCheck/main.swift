import Foundation
import NeedleCore

let videoID = "dQw4w9WgXcQ"
let playlistID = "PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs"

for input in [
    videoID,
    "https://youtu.be/\(videoID)?si=test",
    "https://www.youtube.com/watch?v=\(videoID)&t=2",
    "youtube.com/shorts/\(videoID)"
] {
    precondition(YouTubeURL.source(from: input) == .video(videoID), "Failed: \(input)")
}

for input in [
    "https://www.youtube.com/playlist?list=\(playlistID)",
    "https://www.youtube.com/watch?v=\(videoID)&list=\(playlistID)"
] {
    precondition(YouTubeURL.source(from: input) == .playlist(playlistID), "Failed: \(input)")
}

precondition(YouTubeURL.source(from: "https://example.com/watch?v=\(videoID)") == nil)
precondition(YouTubeQueue.moving(["1", "2", "3"], item: "1", onto: "3") == ["2", "3", "1"])
precondition(YouTubeQueue.moving(["1", "2", "3"], item: "3", onto: "1") == ["3", "1", "2"])
precondition(YouTubeQueue.syncedIndex(currentVideoID: "b", currentIndex: 0, updated: ["a", "b", "c"]) == 1)
precondition(YouTubeQueue.syncedIndex(currentVideoID: "x", currentIndex: 9, updated: ["a", "b", "c"]) == 2)
precondition(YouTubeMetadata.playlistTitle(from: #"<meta property="og:title" content="1003 &amp; NJ">"#) == "1003 & NJ")
print("NeedleCore self-check passed")

precondition(GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
             == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
let accepted = GoogleOAuth.callback("GET /oauth/callback?state=expected&code=ok HTTP/1.1\r\n\r\n", state:"expected")
precondition(try! accepted?.get() == "ok")
for request in [
    "GET /oauth/callback?state=wrong&code=ok HTTP/1.1",
    "GET /oauth/callback?state=expected&state=expected&code=ok HTTP/1.1",
    "GET /oauth/callback?state=expected&code=one&code=two HTTP/1.1",
    "POST /oauth/callback?state=expected&code=ok HTTP/1.1",
    "GET /favicon.ico HTTP/1.1",
    "GET /oauth/callback?state=expected&code=ok&error=denied HTTP/1.1"
] { precondition(GoogleOAuth.callback(request,state:"expected") == nil) }
let client = try! GoogleDesktopClient.read(Data(#"{"installed":{"client_id":"123-example.apps.googleusercontent.com","client_secret":"test"}}"#.utf8))
precondition(client.client_id == "123-example.apps.googleusercontent.com")
precondition((try? GoogleDesktopClient.read(Data(#"{"web":{"client_id":"123-example.apps.googleusercontent.com"}}"#.utf8))) == nil)
precondition(String(data:GoogleOAuth.form(["code":"a+b&c =한"]),encoding:.utf8) == "code=a%2Bb%26c%20%3D%ED%95%9C")
print("OAuth checks passed: PKCE, callback state/duplicates, Desktop config and form escaping.")

let importedConfig = try! JSONEncoder().encode(client)
let bundledFixture = Data(#"{"installed":{"client_id":"456-release-test.apps.googleusercontent.com"}}"#.utf8)
let bundledClient = try! GoogleDesktopClient.select(bundled: bundledFixture, imported: importedConfig)!
precondition(bundledClient.client_id == "456-release-test.apps.googleusercontent.com")
precondition(bundledClient.acceptsToken(issuedTo: bundledClient.client_id))
precondition(!bundledClient.acceptsToken(issuedTo: client.client_id))
precondition(!bundledClient.acceptsToken(issuedTo: nil))
let fallbackClient = try! GoogleDesktopClient.select(bundled: nil, imported: importedConfig)!
precondition(fallbackClient.acceptsToken(issuedTo: client.client_id))
precondition(try! GoogleDesktopClient.select(bundled: nil, imported: nil) == nil)
precondition((try? GoogleDesktopClient.select(bundled: Data(#"{"web":{}}"#.utf8), imported: importedConfig)) == nil)
print("Bundled OAuth checks passed: precedence, imported fallback, invalid config, and token/client binding.")
