import Foundation
import Combine
import AppKit
import CoreGraphics

/// Canon EDSDK camera control, tuned for the EOS RP and 600D.
///
/// Threading model (matches Canon's own macOS sample): every EDSDK call runs on one
/// dedicated serial queue (`sdkQueue`) — USB transfers and JPEG decodes never touch
/// the main thread, which only receives finished CGImages and state updates. This is
/// what keeps the preview at the camera's full EVF rate without lagging the UI.
///
/// Ported behaviors from memoribox's battle-tested edsdkManager:
/// - SaveTo negotiation Both → Host → Camera (600D only accepts card-save)
/// - photo retrieval via DirItemRequestTransfer (RP) or card-scan fallback (600D)
@MainActor
final class CanonCameraService: ObservableObject {
    static let shared = CanonCameraService()

    // MARK: Published state (main actor)

    /// Latest live-view frame — read once as an initial value by CanonEvfPreviewView;
    /// every subsequent frame goes through evfFrameSink instead. Deliberately NOT
    /// @Published: it used to be, and reassigning it 30x/sec fired objectWillChange on
    /// every frame, forcing every view holding @ObservedObject var canon (CaptureView)
    /// to fully re-render its body every frame — the actual cause of preview stutter.
    private(set) var evfImage: CGImage?
    /// True once frames are flowing — the UI's "show preview vs spinner" flag.
    @Published private(set) var evfReady = false
    /// Direct per-frame sink for the preview layer (bypasses SwiftUI re-rendering).
    /// Only one preview view can be "live" at a time — see attachEvfSink/detachEvfSink.
    private(set) var evfFrameSink: ((CGImage) -> Void)?
    /// Identifies whichever NSView currently owns evfFrameSink, so a stale view
    /// tearing down can't clobber a different view that has since taken over (this
    /// race is what froze the preview: WelcomeView's small EVF box and CaptureView's
    /// full-screen one both call attach/detach as SwiftUI swaps them, and dismantle
    /// order between the old and new view isn't guaranteed).
    private weak var evfSinkOwner: AnyObject?

    /// Claims the frame sink for `owner`. Call from makeNSView.
    func attachEvfSink(owner: AnyObject, _ sink: @escaping (CGImage) -> Void) {
        evfSinkOwner = owner
        evfFrameSink = sink
        NSLog("[Canon SDK] EVF sink attached to \(ObjectIdentifier(owner))")
    }

    /// Releases the frame sink, but only if `owner` is still the current owner.
    /// Call from dismantleNSView.
    func detachEvfSink(owner: AnyObject) {
        guard evfSinkOwner === owner else {
            NSLog("[Canon SDK] EVF sink detach ignored — \(ObjectIdentifier(owner)) is not the current owner")
            return
        }
        evfFrameSink = nil
        evfSinkOwner = nil
        NSLog("[Canon SDK] EVF sink detached from \(ObjectIdentifier(owner))")
    }
    /// Per-frame tap invoked on the SDK thread (used by the clip recorder so encoding
    /// consumes real frames at the camera's cadence, never touching the main thread).
    nonisolated(unsafe) var frameTap: ((CGImage) -> Void)?
    @Published private(set) var isConnected = false
    /// Human-readable model name (e.g. "Canon EOS RP") once connected.
    @Published private(set) var cameraName: String?
    /// Transient connect/disconnect message for the UI toast; auto-clears.
    @Published private(set) var toast: String?
    @Published var errorMessage: String?

    private var toastTask: Task<Void, Never>?

    // MARK: SDK-thread state (touched only on sdkQueue)

    private nonisolated let sdkQueue = DispatchQueue(label: "canon.edsdk", qos: .userInitiated)
    nonisolated(unsafe) private var sdkInitialized = false
    nonisolated(unsafe) private var camera: EdsCameraRef?
    nonisolated(unsafe) private var connectedFlag = false
    nonisolated(unsafe) private var evfActive = false
    nonisolated(unsafe) private var evfStream: EdsStreamRef?
    nonisolated(unsafe) private var eventPump: DispatchSourceTimer?
    nonisolated(unsafe) private var evfLoop: DispatchSourceTimer?
    nonisolated(unsafe) private var detectLoop: DispatchSourceTimer?
    nonisolated(unsafe) private var keepAliveLoop: DispatchSourceTimer?
    nonisolated(unsafe) private var photoContinuation: CheckedContinuation<Data, Error>?
    nonisolated(unsafe) private var preShotFilenames: Set<String> = []

    // EDSDK constants (defined locally — the C #defines don't all import cleanly)
    private nonisolated static let propSaveTo: EdsPropertyID = 0x0000000b
    private nonisolated static let propEvfMode: EdsPropertyID = 0x0000_0501
    private nonisolated static let propEvfOutputDevice: EdsPropertyID = 0x0000_0500
    private nonisolated static let evfOutputPC: EdsUInt32 = 2
    private nonisolated static let cmdTakePicture: EdsCameraCommand = 0x0000_0000
    private nonisolated static let cmdExtendShutDownTimer: EdsCameraCommand = 0x0000_0001
    private nonisolated static let eventDirItemCreated: EdsObjectEvent = 0x0000_0204
    private nonisolated static let eventDirItemRequestTransfer: EdsObjectEvent = 0x0000_0208
    private nonisolated static let eventAllObject: EdsObjectEvent = 0x0000_0200
    private nonisolated static let stateEventAll: EdsStateEvent = 0x0000_0300
    private nonisolated static let stateEventShutdown: EdsStateEvent = 0x0000_0301
    private nonisolated static let statusUILock: EdsCameraStatusCommand = 0x0000_0000
    private nonisolated static let statusUIUnlock: EdsCameraStatusCommand = 0x0000_0001
    /// Canon's sample pre-allocates the EVF buffer; avoids re-growing as frame sizes vary.
    private nonisolated static let evfBufferSize: EdsUInt64 = 2 * 1024 * 1024

    // MARK: Lifecycle — app-wide auto-detection

    /// Called once at app start: keeps watching for a Canon body being plugged in or
    /// removed. When one is present it becomes the booth camera; otherwise the webcam.
    func startMonitoring() {
        sdkQueue.async { [self] in
            if !sdkInitialized {
                guard EdsInitializeSDK() == EDS_ERR_OK else {
                    Task { @MainActor in self.errorMessage = "Could not initialize the Canon SDK." }
                    return
                }
                sdkInitialized = true
            }
            startEventPump()
            startDetectLoop()
            startEvfLoop()
        }
    }

    /// Stops the 2-second auto-detect polling — used once another camera (e.g. Sony)
    /// is locked in for the launch, so the SDK stops enumerating in the background.
    /// Call startMonitoring() again to resume detection for the next launch.
    func stopMonitoring() {
        sdkQueue.async { [self] in
            detectLoop?.cancel()
            detectLoop = nil
        }
    }

    /// Wakes the camera (resets its auto power-off timer). If the body already slept,
    /// the dead session is dropped so the detection loop reconnects within seconds.
    func wake() {
        sdkQueue.async { [self] in
            guard connectedFlag, let camera else { return }
            if EdsSendCommand(camera, Self.cmdExtendShutDownTimer, 0) != EDS_ERR_OK {
                sdkHandleDisconnect()
            }
        }
    }

    /// Kiosk turns live view on/off; keeps the camera cool + battery alive between events.
    func setEvfEnabled(_ enabled: Bool) {
        sdkQueue.async { [self] in
            evfActive = enabled
            NSLog("[Canon SDK] setEvfEnabled(\(enabled)) — connected=\(connectedFlag)")
            if connectedFlag {
                enabled ? sdkStartEvf() : sdkStopEvf()
            }
        }
    }

    // MARK: SDK-thread timers

    private nonisolated func makeTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: sdkQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: leeway)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    /// EDSDK delivers callbacks only while EdsGetEvent is pumped.
    private nonisolated func startEventPump() {
        guard eventPump == nil else { return }
        eventPump = makeTimer(interval: .milliseconds(50), leeway: .milliseconds(10)) { [weak self] in
            guard self != nil else { return }
            _ = EdsGetEvent()
        }
    }

    private nonisolated func startDetectLoop() {
        guard detectLoop == nil else { return }
        detectLoop = makeTimer(interval: .seconds(2), leeway: .milliseconds(200)) { [weak self] in
            guard let self, !self.connectedFlag else { return }
            self.sdkTryConnect()
        }
    }

    /// EVF poll at ~120 Hz: when no new frame is ready EDSDK returns OBJECT_NOTREADY
    /// immediately at maximum frequency, so this catches every frame the body produces
    /// (~30 fps on the RP) with ~4ms latency. Runs entirely on the SDK thread.
    private nonisolated func startEvfLoop() {
        guard evfLoop == nil else { return }
        evfLoop = makeTimer(interval: .milliseconds(4), leeway: .milliseconds(0)) { [weak self] in
            guard let self, self.connectedFlag, self.evfActive else { return }
            self.sdkDownloadEvfFrame()
        }
    }

    // MARK: Connect (SDK thread)

    private nonisolated func sdkTryConnect() {
        var listRef: EdsCameraListRef?
        let listResult = EdsGetCameraList(&listRef)
        guard listResult == EDS_ERR_OK, let list = listRef else {
            NSLog("[Canon SDK] EdsGetCameraList failed: 0x%X", listResult)
            return
        }
        defer { EdsRelease(list) }

        var count: EdsUInt32 = 0
        EdsGetChildCount(list, &count)
        guard count > 0 else {
            // Normal "nothing plugged in" case — expected every 2s while idle, so this
            // stays quiet rather than flooding the console like a real error would.
            return
        }
        NSLog("[Canon SDK] Detected %d camera(s), attempting to open session…", count)

        var cameraRef: EdsCameraRef?
        guard EdsGetChildAtIndex(list, 0, &cameraRef) == EDS_ERR_OK, let cam = cameraRef else {
            NSLog("[Canon SDK] EdsGetChildAtIndex failed")
            return
        }

        var deviceInfo = EdsDeviceInfo()
        EdsGetDeviceInfo(cam, &deviceInfo)
        let name = withUnsafeBytes(of: deviceInfo.szDeviceDescription) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        let openResult = EdsOpenSession(cam)
        guard openResult == EDS_ERR_OK else {
            NSLog("[Canon SDK] EdsOpenSession failed for \(name.isEmpty ? "camera" : name): 0x%X", openResult)
            EdsRelease(cam)
            Task { @MainActor in
                self.errorMessage = String(format: "Could not open a session with the Canon camera (error 0x%X). Try unplugging and reconnecting it.", openResult)
            }
            return
        }
        camera = cam
        let displayName = name.isEmpty ? "Canon camera" : name

        let context = Unmanaged.passUnretained(self).toOpaque()

        let objectHandler: EdsObjectEventHandler = { event, ref, ctx in
            guard let ctx else { return EdsError(EDS_ERR_OK) }
            let service = Unmanaged<CanonCameraService>.fromOpaque(ctx).takeUnretainedValue()
            service.sdkHandleObjectEvent(event, ref: ref)
            return EdsError(EDS_ERR_OK)
        }
        EdsSetObjectEventHandler(cam, Self.eventAllObject, objectHandler, context)

        let stateHandler: EdsStateEventHandler = { event, _, ctx in
            guard let ctx else { return EdsError(EDS_ERR_OK) }
            let service = Unmanaged<CanonCameraService>.fromOpaque(ctx).takeUnretainedValue()
            if event == CanonCameraService.stateEventShutdown {
                service.sdkHandleDisconnect()
            }
            return EdsError(EDS_ERR_OK)
        }
        EdsSetCameraStateEventHandler(cam, Self.stateEventAll, stateHandler, context)

        // SaveTo negotiation: Both/Host (newer bodies, direct-to-PC) → Camera (600D, card only).
        var accepted = false
        for var saveTo in [EdsUInt32(3 /* Both */), EdsUInt32(2 /* Host */)] {
            if EdsSetPropertyData(cam, Self.propSaveTo, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &saveTo) == EDS_ERR_OK {
                EdsSendStatusCommand(cam, Self.statusUILock, 0)
                let capacity = EdsCapacity(numberOfFreeClusters: 0x7FFFFFFF, bytesPerSector: 0x1000, reset: 1)
                EdsSetCapacity(cam, capacity)
                EdsSendStatusCommand(cam, Self.statusUIUnlock, 0)
                accepted = true
                break
            }
        }
        if !accepted {
            var saveTo = EdsUInt32(1 /* Camera — 600D path, photos land on the SD card */)
            EdsSetPropertyData(cam, Self.propSaveTo, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &saveTo)
        }

        connectedFlag = true
        NSLog("[Canon SDK] Connected: \(displayName), evfActive=\(evfActive)")
        if evfActive {
            sdkStartEvf()
        }
        startKeepAlive()

        Task { @MainActor in
            self.isConnected = true
            self.cameraName = displayName
            self.errorMessage = nil
            self.showToast("\(displayName) has been connected")
        }
    }

    /// Keep the body awake while connected (booths idle long enough for auto power-off).
    private nonisolated func startKeepAlive() {
        keepAliveLoop?.cancel()
        keepAliveLoop = makeTimer(interval: .seconds(60), leeway: .seconds(5)) { [weak self] in
            guard let self, self.connectedFlag, let cam = self.camera else { return }
            EdsSendCommand(cam, Self.cmdExtendShutDownTimer, 0)
        }
    }

    private nonisolated func sdkHandleDisconnect() {
        NSLog("[Canon SDK] Handling disconnect (was connected: \(connectedFlag))")
        keepAliveLoop?.cancel()
        keepAliveLoop = nil
        sdkStopEvf()
        if let camera {
            EdsRelease(camera)
            self.camera = nil
        }
        connectedFlag = false
        if let continuation = photoContinuation {
            photoContinuation = nil
            continuation.resume(throwing: CanonError.notConnected)
        }
        Task { @MainActor in
            let name = self.cameraName ?? "Canon camera"
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

    // MARK: Live view (SDK thread)

    private nonisolated func sdkStartEvf() {
        guard let camera else {
            NSLog("[Canon SDK] sdkStartEvf called with no camera session — skipping")
            return
        }
        var mode: EdsUInt32 = 1
        let modeResult = EdsSetPropertyData(camera, Self.propEvfMode, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &mode)
        var device: EdsUInt32 = Self.evfOutputPC
        let deviceResult = EdsSetPropertyData(camera, Self.propEvfOutputDevice, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
        if modeResult != EDS_ERR_OK || deviceResult != EDS_ERR_OK {
            NSLog("[Canon SDK] sdkStartEvf: propEvfMode=0x%X propEvfOutputDevice=0x%X", modeResult, deviceResult)
        }
        if evfStream == nil {
            var streamRef: EdsStreamRef?
            if EdsCreateMemoryStream(Self.evfBufferSize, &streamRef) == EDS_ERR_OK {
                evfStream = streamRef
                NSLog("[Canon SDK] EVF stream created, live view starting")
            } else {
                NSLog("[Canon SDK] EdsCreateMemoryStream failed for EVF buffer")
            }
        }
    }

    private nonisolated func sdkStopEvf() {
        if let evfStream {
            EdsRelease(evfStream)
            self.evfStream = nil
        }
        if let camera {
            var device: EdsUInt32 = 0
            EdsSetPropertyData(camera, Self.propEvfOutputDevice, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
        }
        Task { @MainActor in
            self.evfReady = false
            self.evfImage = nil
        }
    }

    private nonisolated func sdkDownloadEvfFrame() {
        guard let camera, let stream = evfStream else { return }

        var evfRef: EdsEvfImageRef?
        guard EdsCreateEvfImageRef(stream, &evfRef) == EDS_ERR_OK, let evf = evfRef else { return }
        defer { EdsRelease(evf) }

        // Returns OBJECT_NOTREADY (cheaply) until the camera has a new frame — that's the
        // normal steady state between frames, so it's not logged (would spam at ~120Hz).
        let downloadResult = EdsDownloadEvfImage(camera, evf)
        guard downloadResult == EDS_ERR_OK else { return }

        var pointer: UnsafeMutableRawPointer?
        var length: EdsUInt64 = 0
        EdsGetPointer(stream, &pointer)
        EdsGetLength(stream, &length)
        guard let pointer, length > 0 else { return }

        // Decode here on the SDK thread. ShouldCacheImmediately forces the JPEG
        // decompression to happen NOW (on this thread) instead of lazily at first draw
        // (which would land back on the main thread and stutter the preview).
        let data = Data(bytes: pointer, count: Int(length))
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return }

        // Clip recorder consumes frames right here at camera cadence (its own queue).
        frameTap?(image)

        DispatchQueue.main.async {
            let service = CanonCameraService.shared
            service.evfImage = image
            // Only publish when this actually flips false→true — @Published fires
            // objectWillChange on every assignment regardless of value equality, and
            // this callback runs every frame (~30fps), so reassigning true→true here
            // would re-render every view observing the service on every single frame.
            if !service.evfReady {
                service.evfReady = true
                NSLog("[Canon SDK] First EVF frame decoded — live view is now ready")
            }
            service.evfFrameSink?(image)
        }
    }

    // MARK: Capture

    /// Takes a photo and returns the full-resolution JPEG.
    /// RP path: camera pushes the file (DirItemRequestTransfer).
    /// 600D path: photo lands on the SD card; detected by comparing card contents
    /// against a snapshot taken just before the shutter.
    func capturePhoto() async throws -> Data {
        guard isConnected else {
            NSLog("[Canon SDK] capturePhoto() called while not connected")
            throw CanonError.notConnected
        }
        NSLog("[Canon SDK] capturePhoto() requested")
        return try await withCheckedThrowingContinuation { continuation in
            sdkQueue.async { [self] in
                guard connectedFlag, let camera else {
                    NSLog("[Canon SDK] capturePhoto: no active session on sdkQueue")
                    continuation.resume(throwing: CanonError.notConnected)
                    return
                }
                preShotFilenames = sdkSnapshotCardFilenames()
                NSLog("[Canon SDK] Sending shutter command (card snapshot: \(preShotFilenames.count) files)")

                let result = EdsSendCommand(camera, Self.cmdTakePicture, 0)
                guard result == EDS_ERR_OK else {
                    NSLog("[Canon SDK] Shutter command failed: 0x%X", result)
                    continuation.resume(throwing: CanonError.shutterFailed(result))
                    return
                }
                NSLog("[Canon SDK] Shutter fired, waiting for the object event / card scan")
                photoContinuation = continuation

                // 600D safety net: if no object event ever arrives, scan the card anyway.
                sdkQueue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.photoContinuation != nil else { return }
                    NSLog("[Canon SDK] No object event after 6s — falling back to card scan")
                    self.sdkScanCardForNewPhoto(attempt: 0)
                }
                // Hard timeout: slow SD cards can take a while.
                sdkQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self else { return }
                    if self.photoContinuation != nil {
                        NSLog("[Canon SDK] Transfer timed out after 30s")
                    }
                    self.sdkFinishCapture(.failure(CanonError.transferTimeout))
                }
            }
        }
    }

    private nonisolated func sdkFinishCapture(_ result: Result<Data, Error>) {
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        switch result {
        case .success(let data): NSLog("[Canon SDK] Capture finished: \(data.count) bytes")
        case .failure(let error): NSLog("[Canon SDK] Capture failed: \(error.localizedDescription)")
        }
        continuation.resume(with: result)
    }

    private nonisolated func sdkHandleObjectEvent(_ event: EdsObjectEvent, ref: EdsBaseRef?) {
        switch event {
        case Self.eventDirItemRequestTransfer:
            // Newer bodies (EOS RP): direct pull of the offered file.
            NSLog("[Canon SDK] eventDirItemRequestTransfer received — pulling file directly")
            guard let ref else {
                NSLog("[Canon SDK] eventDirItemRequestTransfer had no ref")
                return
            }
            if let data = sdkDownloadDirectoryItem(ref) {
                sdkFinishCapture(.success(data))
            } else {
                NSLog("[Canon SDK] sdkDownloadDirectoryItem returned nil for direct transfer")
            }
            EdsRelease(ref)
        case Self.eventDirItemCreated:
            // 600D: this ref is just a notification handle, not downloadable (err 0x61).
            // Give the camera time to finish writing, then scan the card.
            NSLog("[Canon SDK] eventDirItemCreated received — scheduling card scan in 2.5s")
            if let ref { EdsRelease(ref) }
            sdkQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.sdkScanCardForNewPhoto(attempt: 0)
            }
        default:
            break
        }
    }

    // MARK: Card scan (600D photo retrieval, SDK thread)

    private nonisolated func sdkScanCardForNewPhoto(attempt: Int) {
        guard photoContinuation != nil else { return }
        if let item = sdkFindNewCardItem() {
            let data = sdkDownloadDirectoryItem(item)
            EdsRelease(item)
            if let data {
                NSLog("[Canon SDK] Card scan found new photo on attempt \(attempt)")
                sdkFinishCapture(.success(data))
                return
            }
        }
        // The 600D can take a couple of seconds to finish writing to a slow card.
        if attempt < 6 {
            NSLog("[Canon SDK] Card scan attempt \(attempt): no new photo yet, retrying")
            sdkQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.sdkScanCardForNewPhoto(attempt: attempt + 1)
            }
        } else {
            NSLog("[Canon SDK] Card scan exhausted all attempts — photo not found")
            sdkFinishCapture(.failure(CanonError.photoNotFoundOnCard))
        }
    }

    /// Walks camera → volume → DCIM → subfolders and returns the first JPEG
    /// that wasn't on the card before the shutter. Caller releases the returned ref.
    private nonisolated func sdkFindNewCardItem() -> EdsDirectoryItemRef? {
        var newest: EdsDirectoryItemRef?
        sdkEnumerateCardFiles { name, itemRef in
            if !preShotFilenames.contains(name), name.uppercased().hasSuffix(".JPG") {
                if let previous = newest { EdsRelease(previous) }
                EdsRetain(itemRef)
                newest = itemRef
            }
        }
        return newest
    }

    private nonisolated func sdkSnapshotCardFilenames() -> Set<String> {
        var names: Set<String> = []
        sdkEnumerateCardFiles { name, _ in names.insert(name) }
        return names
    }

    /// Calls `visit` for every file in every DCIM subfolder of the first volume.
    private nonisolated func sdkEnumerateCardFiles(_ visit: (String, EdsDirectoryItemRef) -> Void) {
        guard let camera else { return }
        var volumeCount: EdsUInt32 = 0
        guard EdsGetChildCount(camera, &volumeCount) == EDS_ERR_OK, volumeCount > 0 else { return }
        var volumeRef: EdsVolumeRef?
        guard EdsGetChildAtIndex(camera, 0, &volumeRef) == EDS_ERR_OK, let volume = volumeRef else { return }
        defer { EdsRelease(volume) }

        var folderCount: EdsUInt32 = 0
        EdsGetChildCount(volume, &folderCount)
        for folderIndex in 0..<Int(folderCount) {
            var folderRef: EdsDirectoryItemRef?
            guard EdsGetChildAtIndex(volume, EdsInt32(folderIndex), &folderRef) == EDS_ERR_OK, let folder = folderRef else { continue }
            defer { EdsRelease(folder) }

            var folderInfo = EdsDirectoryItemInfo()
            guard EdsGetDirectoryItemInfo(folder, &folderInfo) == EDS_ERR_OK,
                  Self.itemName(folderInfo) == "DCIM" else { continue }

            var subCount: EdsUInt32 = 0
            EdsGetChildCount(folder, &subCount)
            for subIndex in 0..<Int(subCount) {
                var subRef: EdsDirectoryItemRef?
                guard EdsGetChildAtIndex(folder, EdsInt32(subIndex), &subRef) == EDS_ERR_OK, let sub = subRef else { continue }
                defer { EdsRelease(sub) }

                var fileCount: EdsUInt32 = 0
                EdsGetChildCount(sub, &fileCount)
                for fileIndex in 0..<Int(fileCount) {
                    var fileRef: EdsDirectoryItemRef?
                    guard EdsGetChildAtIndex(sub, EdsInt32(fileIndex), &fileRef) == EDS_ERR_OK, let file = fileRef else { continue }
                    var fileInfo = EdsDirectoryItemInfo()
                    if EdsGetDirectoryItemInfo(file, &fileInfo) == EDS_ERR_OK {
                        visit(Self.itemName(fileInfo), file)
                    }
                    EdsRelease(file)
                }
            }
        }
    }

    private nonisolated func sdkDownloadDirectoryItem(_ item: EdsBaseRef) -> Data? {
        var info = EdsDirectoryItemInfo()
        guard EdsGetDirectoryItemInfo(item, &info) == EDS_ERR_OK, info.size > 0 else { return nil }

        var streamRef: EdsStreamRef?
        guard EdsCreateMemoryStream(0, &streamRef) == EDS_ERR_OK, let stream = streamRef else { return nil }
        defer { EdsRelease(stream) }

        guard EdsDownload(item, info.size, stream) == EDS_ERR_OK else { return nil }
        EdsDownloadComplete(item)

        var pointer: UnsafeMutableRawPointer?
        var length: EdsUInt64 = 0
        EdsGetPointer(stream, &pointer)
        EdsGetLength(stream, &length)
        guard let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: Int(length))
    }

    private nonisolated static func itemName(_ info: EdsDirectoryItemInfo) -> String {
        withUnsafeBytes(of: info.szFileName) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    enum CanonError: LocalizedError {
        case notConnected
        case shutterFailed(EdsError)
        case transferTimeout
        case photoNotFoundOnCard

        var errorDescription: String? {
            switch self {
            case .notConnected: "Canon camera is not connected."
            case .shutterFailed(let code): String(format: "Shutter failed (EDSDK error 0x%X).", code)
            case .transferTimeout: "The photo transfer timed out."
            case .photoNotFoundOnCard: "Could not find the new photo on the memory card."
            }
        }
    }
}
