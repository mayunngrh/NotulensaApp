import Foundation
import Combine
import AppKit
import CoreGraphics

/// Sony Camera Remote SDK (CrSDK) camera control for supported models (A7 Mark IV, etc).
///
/// Threading model: camera control and live view streaming run on a dedicated serial queue
/// (sonyQueue) to avoid blocking the main thread. Frames are decoded on the SDK thread and
/// passed to the main thread for UI consumption via evfFrameSink and frameTap callbacks.
///
/// This service mirrors CanonCameraService's public interface to allow seamless swapping
/// between Canon and Sony cameras at runtime.
@MainActor
final class SonyCameraService: ObservableObject {
    static let shared = SonyCameraService()

    // MARK: Published state (main actor)

    /// Latest live-view frame — read once at startup, then updated via evfFrameSink.
    /// NOT @Published to avoid excessive re-renders (same rationale as CanonCameraService).
    private(set) var evfImage: CGImage?
    /// True once live view frames are flowing.
    @Published private(set) var evfReady = false
    /// Direct per-frame sink for the preview layer.
    /// Only one preview view can be "live" at a time — see attachEvfSink/detachEvfSink.
    private(set) var evfFrameSink: ((CGImage) -> Void)?
    /// Identifies whichever NSView currently owns evfFrameSink, so a stale view
    /// tearing down can't clobber a different view that has since taken over
    /// (same race that froze the Canon preview — see CanonCameraService).
    private weak var evfSinkOwner: AnyObject?

    /// Claims the frame sink for `owner`. Call from makeNSView.
    func attachEvfSink(owner: AnyObject, _ sink: @escaping (CGImage) -> Void) {
        evfSinkOwner = owner
        evfFrameSink = sink
    }

    /// Releases the frame sink, but only if `owner` is still the current owner.
    /// Call from dismantleNSView.
    func detachEvfSink(owner: AnyObject) {
        guard evfSinkOwner === owner else { return }
        evfFrameSink = nil
        evfSinkOwner = nil
    }
    /// Per-frame tap invoked on the SDK thread (used by the clip recorder).
    nonisolated(unsafe) var frameTap: ((CGImage) -> Void)?
    @Published private(set) var isConnected = false
    /// Human-readable model name (e.g. "Sony Alpha 7 Mark IV") once connected.
    @Published private(set) var cameraName: String?
    /// Transient connect/disconnect message for the UI toast; auto-clears.
    @Published private(set) var toast: String?
    @Published var errorMessage: String?

    private var toastTask: Task<Void, Never>?

    // MARK: SDK-thread state (touched only on sonyQueue)

    private nonisolated let sonyQueue = DispatchQueue(label: "sony.crsdk", qos: .userInitiated)
    nonisolated(unsafe) private var sdkInitialized = false
    nonisolated(unsafe) private var connectedFlag = false
    nonisolated(unsafe) private var evfActive = false
    nonisolated(unsafe) private var eventPump: DispatchSourceTimer?
    nonisolated(unsafe) private var evfLoop: DispatchSourceTimer?
    nonisolated(unsafe) private var detectLoop: DispatchSourceTimer?
    nonisolated(unsafe) private var keepAliveLoop: DispatchSourceTimer?
    nonisolated(unsafe) private var photoContinuation: CheckedContinuation<Data, Error>?

    // MARK: Lifecycle — app-wide auto-detection

    /// Called once at app start: keeps watching for a Sony camera being connected.
    func startMonitoring() {
        sonyQueue.async { [self] in
            if !sdkInitialized {
                guard self.sdkInitialize() else {
                    Task { @MainActor in
                        self.errorMessage = "Could not initialize the Sony CrSDK."
                    }
                    return
                }
                sdkInitialized = true
            }
            startEventPump()
            startDetectLoop()
            startEvfLoop()
        }
    }

    /// Stops the 2-second auto-detect polling — used once another camera (e.g. Canon)
    /// is locked in for the launch, so the SDK stops enumerating in the background.
    /// Call startMonitoring() again to resume detection for the next launch.
    func stopMonitoring() {
        sonyQueue.async { [self] in
            detectLoop?.cancel()
            detectLoop = nil
        }
    }

    /// Wakes the camera (resets its auto power-off timer).
    func wake() {
        sonyQueue.async { [self] in
            guard connectedFlag else { return }
            sdkKeepAlive()
        }
    }

    /// Kiosk turns live view on/off; keeps the camera cool + battery alive between events.
    func setEvfEnabled(_ enabled: Bool) {
        sonyQueue.async { [self] in
            evfActive = enabled
            if connectedFlag {
                enabled ? sdkStartEvf() : sdkStopEvf()
            }
        }
    }

    // MARK: SDK-thread timers

    private nonisolated func makeTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: sonyQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    /// CrSDK event pump — ensures callbacks are processed.
    private nonisolated func startEventPump() {
        guard eventPump == nil else { return }
        eventPump = makeTimer(interval: .milliseconds(50), leeway: .milliseconds(10)) { [weak self] in
            guard self != nil else { return }
            // Placeholder: CrSDK event processing will go here (e.g., CrAPI_PollEvent)
        }
    }

    private nonisolated func startDetectLoop() {
        guard detectLoop == nil else { return }
        detectLoop = makeTimer(interval: .seconds(2), leeway: .milliseconds(200)) { [weak self] in
            guard let self else { return }
            if self.connectedFlag {
                // The SDK's own callback flags disconnects asynchronously; catch it here
                // since nothing else polls for it once the initial connect succeeds.
                if !SonyCrSDK_IsConnected() {
                    self.sdkHandleDisconnect()
                }
            } else {
                self.sdkTryConnect()
            }
        }
    }

    /// EVF poll at ~30 Hz to match camera frame rate.
    private nonisolated func startEvfLoop() {
        guard evfLoop == nil else { return }
        evfLoop = makeTimer(interval: .milliseconds(33), leeway: .milliseconds(0)) { [weak self] in
            guard let self, self.connectedFlag, self.evfActive else { return }
            self.sdkDownloadEvfFrame()
        }
    }

    // MARK: SDK initialization and connection (SDK thread)

    private nonisolated func sdkInitialize() -> Bool {
        return SonyCrSDK_Initialize()
    }

    private nonisolated func sdkTryConnect() {
        // Try to connect to first available camera (index 0)
        guard SonyCrSDK_ConnectCamera(0) else { return }

        let nameC = SonyCrSDK_GetCameraName()
        let displayName = nameC.map { String(cString: $0) } ?? "Sony camera"

        connectedFlag = true
        if evfActive {
            sdkStartEvf()
        }
        startKeepAlive()

        Task { @MainActor in
            self.isConnected = true
            self.cameraName = displayName
            self.showToast("\(displayName) has been connected")
        }
    }

    private nonisolated func sdkHandleDisconnect() {
        keepAliveLoop?.cancel()
        keepAliveLoop = nil
        sdkStopEvf()
        SonyCrSDK_DisconnectCamera()
        connectedFlag = false
        if let continuation = photoContinuation {
            photoContinuation = nil
            continuation.resume(throwing: SonyError.notConnected)
        }
        Task { @MainActor in
            let name = self.cameraName ?? "Sony camera"
            self.isConnected = false
            self.cameraName = nil
            self.evfImage = nil
            self.evfReady = false
            self.showToast("\(name) has been disconnected — switching to webcam")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// Keep the camera awake while connected.
    private nonisolated func startKeepAlive() {
        keepAliveLoop?.cancel()
        keepAliveLoop = makeTimer(interval: .seconds(60), leeway: .seconds(5)) { [weak self] in
            guard let self, self.connectedFlag else { return }
            self.sdkKeepAlive()
        }
    }

    // MARK: Live view (SDK thread)

    private nonisolated func sdkStartEvf() {
        guard connectedFlag else { return }
        _ = SonyCrSDK_StartLiveView()
        // evfReady flips true on the first successfully decoded frame, not here —
        // matches Canon's "show preview vs spinner" semantics.
    }

    private nonisolated func sdkStopEvf() {
        SonyCrSDK_StopLiveView()
        Task { @MainActor in
            self.evfReady = false
            self.evfImage = nil
        }
    }

    private nonisolated func sdkDownloadEvfFrame() {
        guard connectedFlag else { return }

        var jpegDataPtr: UnsafeMutablePointer<UInt8>?
        var jpegSize: Int32 = 0
        guard SonyCrSDK_GetLiveViewImage(&jpegDataPtr, &jpegSize),
              jpegSize > 0,
              let ptr = jpegDataPtr else { return }
        defer { SonyCrSDK_FreeMemory(ptr) }

        // Decode here on the SDK thread — matches Canon's approach so JPEG decompression
        // never lands on the main thread and stutters the preview.
        let data = Data(bytes: ptr, count: Int(jpegSize))
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return }

        // Clip recorder consumes frames right here at camera cadence, same as Canon.
        frameTap?(image)

        DispatchQueue.main.async {
            let service = SonyCameraService.shared
            service.evfImage = image
            if !service.evfReady { service.evfReady = true }
            service.evfFrameSink?(image)
        }
    }

    private nonisolated func sdkKeepAlive() {
        guard connectedFlag else { return }
        // Live view polling itself keeps the session alive; nothing extra needed here.
    }

    // MARK: Capture

    /// Takes a photo and returns the full-resolution JPEG.
    func capturePhoto() async throws -> Data {
        guard isConnected else { throw SonyError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            sonyQueue.async { [self] in
                guard connectedFlag else {
                    continuation.resume(throwing: SonyError.notConnected)
                    return
                }

                var jpegDataPtr: UnsafeMutablePointer<UInt8>?
                var jpegSize: Int32 = 0

                guard SonyCrSDK_CaptureImage(&jpegDataPtr, &jpegSize),
                      jpegSize > 0,
                      let ptr = jpegDataPtr else {
                    continuation.resume(throwing: SonyError.shutterFailed(0))
                    return
                }

                defer { SonyCrSDK_FreeMemory(ptr) }
                let jpegData = Data(bytes: ptr, count: Int(jpegSize))
                continuation.resume(returning: jpegData)
            }
        }
    }

    private nonisolated func sdkFinishCapture(_ result: Result<Data, Error>) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(with: result)
    }
}

// MARK: Error types

enum SonyError: LocalizedError {
    case notConnected
    case shutterFailed(Int)
    case transferTimeout
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Sony camera is not connected."
        case .shutterFailed(let code):
            return "Sony camera shutter failed (error \(code))."
        case .transferTimeout:
            return "Sony camera photo transfer timed out."
        case .invalidFrame:
            return "Could not decode live view frame from Sony camera."
        }
    }
}
