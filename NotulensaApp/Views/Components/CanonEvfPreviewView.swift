import SwiftUI
import AppKit
import QuartzCore

/// Canon live-view preview that draws frames straight into a CALayer.
/// Frames arrive via CanonCameraService.evfFrameSink, so SwiftUI never re-renders
/// per frame — Core Animation just swaps the layer contents (cheapest possible path).
struct CanonEvfPreviewView: NSViewRepresentable {
    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        CanonCameraService.shared.evfFrameSink = { [weak view] frame in
            view?.show(frame)
        }
        if let current = CanonCameraService.shared.evfImage {
            view.show(current)
        }
        return view
    }

    func updateNSView(_ nsView: FrameView, context: Context) {}

    static func dismantleNSView(_ nsView: FrameView, coordinator: ()) {
        MainActor.assumeIsolated {
            CanonCameraService.shared.evfFrameSink = nil
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
