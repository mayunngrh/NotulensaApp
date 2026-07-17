import SwiftUI
import AVFoundation
import AppKit

/// Live camera preview, mirrored (selfie-style) to match the mirrored captures.
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    /// `.resizeAspectFill` (default) fills + crops the frame; `.resizeAspect` fits the
    /// whole video inside the frame (letterboxed) — used by landscape preview so a wide
    /// source shows fit-to-width and centered on a portrait screen.
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.videoGravity = videoGravity
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.previewLayer.videoGravity = videoGravity
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            // AppKit implicitly fades in a layer-backed view's content the first time it's
            // displayed; disable that so the preview appears instantly instead of fading in.
            previewLayer.actions = ["contents": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}
