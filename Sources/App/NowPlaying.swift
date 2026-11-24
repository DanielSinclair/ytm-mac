import AppKit
import MediaPlayer
import WebKit

/// Bridges the page's playback state to macOS Now Playing (Control Center,
/// media keys, AirPods/headphone buttons) and routes remote commands back.
@MainActor
final class NowPlaying: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var artworkURL = ""
    private var artwork: MPMediaItemArtwork?
    private var activity: NSObjectProtocol? // prevents App Nap while playing

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        let cc = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ js: String) {
            cmd.addTarget { [weak self] _ in self?.run(js); return .success }
        }
        on(cc.playCommand, "play()")
        on(cc.pauseCommand, "pause()")
        on(cc.togglePlayPauseCommand, "toggle()")
        on(cc.nextTrackCommand, "next()")
        on(cc.previousTrackCommand, "previous()")
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.run("seek(\(e.positionTime))")
            return .success
        }
    }

    private func run(_ call: String) {
        webView?.evaluateJavaScript("window.__ytm && window.__ytm.\(call)")
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? [String: Any] else { return }
        let title = s["title"] as? String ?? "", artist = s["artist"] as? String ?? ""
        let album = s["album"] as? String ?? "", art = s["artwork"] as? String ?? ""
        let duration = s["duration"] as? Double ?? 0, position = s["position"] as? Double ?? 0
        let playing = s["playing"] as? Bool ?? false
        MainActor.assumeIsolated {
            update(title: title, artist: artist, album: album, art: art,
                   duration: duration, position: position, playing: playing)
        }
    }

    private func update(title: String, artist: String, album: String, art: String,
                        duration: Double, position: Double, playing: Bool) {
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Playing music")
        } else if !playing, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }

        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if art == artworkURL, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused

        if art != artworkURL, let url = URL(string: art) {
            artworkURL = art
            artwork = nil
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data), let self, self.artworkURL == art else { return }
                let item = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.artwork = item
                center.nowPlayingInfo?[MPMediaItemPropertyArtwork] = item
            }
        }
    }
}
