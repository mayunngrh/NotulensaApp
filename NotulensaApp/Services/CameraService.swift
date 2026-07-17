import Foundation
import Combine
import AVFoundation
import AppKit

@MainActor
final class CameraService: ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var movieDelegate: MovieRecordingDelegate?
    private var device: AVCaptureDevice?
    private var disconnectObserver: NSObjectProtocol?
    @Published private(set) var isConfigured = false
    /// True once the device is configured and its input hasn't been unplugged.
    /// Distinct from `isConfigured` (which never goes back to false): this flips to
    /// false the moment the physical device disconnects, so a session that locked
    /// onto the webcam can detect the disconnect instead of silently continuing.
    @Published private(set) var isConnected = false
    @Published var errorMessage: String?

    func start() async {
        guard await requestAccess() else {
            errorMessage = "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
            return
        }
        if !isConfigured {
            configure()
        }
        guard isConfigured else { return }
        isConnected = true
        let session = self.session
        Task.detached { session.startRunning() }
    }

    func stop() {
        let session = self.session
        Task.detached { session.stopRunning() }
    }

    /// Ensures the session is running and ready before taking a photo.
    func warm() {
        guard isConfigured else { return }
        let session = self.session
        Task.detached {
            if !session.isRunning {
                session.startRunning()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configure() {
        // .external / .continuityCamera are macOS 14+; fall back to any video device on 13.
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(contentsOf: [.external, .continuityCamera])
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            errorMessage = "No camera found."
            return
        }
        self.device = device
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device, queue: .main
        ) { [weak self] _ in
            self?.isConnected = false
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
                errorMessage = "Could not configure camera session."
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.addOutput(photoOutput)
            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
                if let connection = movieOutput.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
            session.commitConfiguration()
            isConfigured = true
        } catch {
            session.commitConfiguration()
            errorMessage = "Camera error: \(error.localizedDescription)"
        }
    }

    /// Captures one still and returns JPEG data (mirrored to match the selfie-style preview).
    func capturePhoto() async throws -> Data {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        let delegate = PhotoCaptureDelegate()
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            photoOutput.capturePhoto(with: settings, delegate: delegate)
            // Keep the delegate alive until the callback fires.
            objc_setAssociatedObject(photoOutput, Unmanaged.passUnretained(delegate).toOpaque(), delegate, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    // MARK: Clip recording (for the live photo output)

    /// Starts recording a video clip; safe to call while previewing.
    func startRecording(to url: URL) {
        guard isConfigured, !movieOutput.isRecording else { return }
        try? FileManager.default.removeItem(at: url)
        let delegate = MovieRecordingDelegate()
        movieDelegate = delegate
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
    }

    /// Stops the current recording and returns the clip URL (nil if nothing recorded or it failed).
    func stopRecording() async -> URL? {
        guard movieOutput.isRecording, let delegate = movieDelegate else { return nil }
        return await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            movieOutput.stopRecording()
        }
    }
}

private final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    nonisolated(unsafe) var continuation: CheckedContinuation<URL?, Never>?

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        continuation?.resume(returning: error == nil ? outputFileURL : nil)
        continuation = nil
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    nonisolated(unsafe) var continuation: CheckedContinuation<Data, Error>?

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation(), let mirrored = Self.mirrorJPEG(data) {
            continuation?.resume(returning: mirrored)
        } else {
            continuation?.resume(throwing: NSError(domain: "Camera", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty photo data"]))
        }
        continuation = nil
    }

    /// Flip horizontally so the saved photo matches the mirrored live preview.
    private nonisolated static func mirrorJPEG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flipped = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: flipped)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }
}
