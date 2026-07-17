import SwiftUI
import AppKit
import QuartzCore

/// Sony live-view preview that draws frames straight into a CALayer.
/// Frames arrive via SonyCameraService.evfFrameSink, so SwiftUI never re-renders
/// per frame — Core Animation just swaps the layer contents (cheapest possible path).
struct SonyEvfPreviewView: NSViewRepresentable {
    /// `.resizeAspectFill` (default) fills + crops; `.resizeAspect` fits the whole frame
    /// (letterboxed) — used by landscape preview to show fit-to-width on a portrait screen.
    var contentsGravity: CALayerContentsGravity = .resizeAspectFill

    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        view.layer?.contentsGravity = contentsGravity
        SonyCameraService.shared.attachEvfSink(owner: view) { [weak view] frame in
            view?.show(frame)
        }
        if let current = SonyCameraService.shared.evfImage {
            view.show(current)
        }
        return view
    }

    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.layer?.contentsGravity = contentsGravity
    }

    static func dismantleNSView(_ nsView: FrameView, coordinator: ()) {
        MainActor.assumeIsolated {
            SonyCameraService.shared.detachEvfSink(owner: nsView)
        }
    }

    final class FrameView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.black.cgColor
            // No implicit animations — contents must swap instantly at video rate.
            layer?.actions = ["contents": NSNull()]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show(_ image: CGImage) {
            layer?.contents = image
        }
    }
}
