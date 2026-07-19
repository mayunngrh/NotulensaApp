import SwiftUI
import AVKit

/// Replacement for SwiftUI's `VideoPlayer`, which crashes at generic metadata
/// instantiation on this OS/SDK combo (_AVKit_SwiftUI abort in
/// _swift_initClassMetadataImpl). Wraps AVKit's AppKit `AVPlayerView` directly,
/// bypassing the buggy SwiftUI generic path entirely.
struct StablePlayerView: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .none
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        view.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.controlsStyle = controlsStyle
        nsView.videoGravity = videoGravity
    }
}
