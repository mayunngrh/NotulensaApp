import Foundation
import AppKit
import CoreGraphics

/// Canon EDSDK camera control, tuned for the EOS 600D (with the newer-body path kept
/// for the EOS RP). Ported from memoribox's battle-tested edsdkManager:
/// - SaveTo negotiation Both → Host → Camera (600D only accepts card-save)
/// - photo retrieval via DirItemRequestTransfer (RP) or card-scan fallback (600D)
/// - EVF live view polled every 50 ms
/// All EDSDK calls happen on the main thread (the SDK's event pump requirement on macOS).
@Observable
@MainActor
final class CanonCameraService {
    static let shared = CanonCameraService()

    /// Latest live-view frame, ready to draw.
    private(set) var evfImage: CGImage?
    private(set) var isConnected = false
    /// Human-readable model name (e.g. "Canon EOS 600D") once connected.
    private(set) var cameraName: String?
    /// Transient connect/disconnect message for the UI toast; auto-clears.
    private(set) var toast: String?
    var errorMessage: String?

    private var sdkInitialized = false
    private var camera: EdsCameraRef?
    private var eventTimer: Timer?
    private var evfTimer: Timer?
    private var detectTimer: Timer?
    private var keepAliveTimer: Timer?
    private var toastTask: Task<Void, Never>?
    /// Kiosk sets this; EVF only streams while it's on (and a camera is connected).
    private var evfEnabled = false

    // Capture state
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var preShotFilenames: Set<String> = []
    private var captureTimeoutTask: Task<Void, Never>?
    private var cardScanFallbackTask: Task<Void, Never>?

    // EDSDK constants (defined locally — the C #defines don't all import cleanly)
    private let propSaveTo: EdsPropertyID = 0x0000000b
    private let propEvfMode: EdsPropertyID = 0x0000_0501
    private let propEvfOutputDevice: EdsPropertyID = 0x0000_0500
    private let evfOutputPC: EdsUInt32 = 2
    private let cmdTakePicture: EdsCameraCommand = 0x0000_0000
    /// Resets the camera's auto power-off countdown — the EDSDK "keep awake" command.
    private let cmdExtendShutDownTimer: EdsCameraCommand = 0x0000_0001
    private let eventDirItemCreated: EdsObjectEvent = 0x0000_0204
    private let eventDirItemRequestTransfer: EdsObjectEvent = 0x0000_0208
    private let eventAll: EdsObjectEvent = 0x0000_0200
    private let statusUILock: EdsCameraStatusCommand = 0x0000_0000
    private let statusUIUnlock: EdsCameraStatusCommand = 0x0000_0001

    // MARK: Lifecycle — app-wide auto-detection

    /// Called once at app start: keeps watching for a Canon body being plugged in or removed.
    /// When one is present it becomes the booth camera; otherwise the webcam is used.
    func startMonitoring() {
        if !sdkInitialized {
            guard EdsInitializeSDK() == EDS_ERR_OK else {
                errorMessage = "Could not initialize the Canon SDK."
                return
            }
            sdkInitialized = true
        }
        startEventPump()
        guard detectTimer == nil else { return }
        tryConnect()
        detectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let service = CanonCameraService.shared
                if !service.isConnected {
                    service.tryConnect()
                }
            }
        }
    }

    /// Wakes the camera before a session: resets its auto power-off timer, and if the
    /// body already went to sleep (command fails), drops the dead session so the
    /// detection loop reconnects within a couple of seconds.
    func wake() {
        guard isConnected, let camera else { return }
        let result = EdsSendCommand(camera, cmdExtendShutDownTimer, 0)
        if result != EDS_ERR_OK {
            handleDisconnect()
        }
    }

    /// Kiosk turns live view on/off; keeps the camera cool + battery alive between events.
    func setEvfEnabled(_ enabled: Bool) {
        evfEnabled = enabled
        if enabled, isConnected {
            startEvf()
        } else {
            stopEvf()
        }
    }

    private func handleDisconnect() {
        let name = cameraName ?? "Canon camera"
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        stopEvf()
        if let camera {
            EdsRelease(camera)
            self.camera = nil
        }
        isConnected = false
        cameraName = nil
        evfImage = nil
        finishCapture(.failure(CanonError.notConnected))
        showToast("\(name) has been disconnected — switching to webcam")
    }

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    /// EDSDK delivers callbacks only while EdsGetEvent is pumped.
    private func startEventPump() {
        guard eventTimer == nil else { return }
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                _ = EdsGetEvent()
            }
        }
    }

    // MARK: Connect

    private func tryConnect() {
        var listRef: EdsCameraListRef?
        guard EdsGetCameraList(&listRef) == EDS_ERR_OK, let list = listRef else { return }
        defer { EdsRelease(list) }

        var count: EdsUInt32 = 0
        EdsGetChildCount(list, &count)
        guard count > 0 else { return }

        var cameraRef: EdsCameraRef?
        guard EdsGetChildAtIndex(list, 0, &cameraRef) == EDS_ERR_OK, let cam = cameraRef else { return }

        var deviceInfo = EdsDeviceInfo()
        EdsGetDeviceInfo(cam, &deviceInfo)
        let name = withUnsafeBytes(of: deviceInfo.szDeviceDescription) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        guard EdsOpenSession(cam) == EDS_ERR_OK else {
            EdsRelease(cam)
            return
        }
        camera = cam
        cameraName = name.isEmpty ? "Canon camera" : name

        // Disconnect notification (camera powered off or cable pulled).
        let stateContext = Unmanaged.passUnretained(self).toOpaque()
        let stateHandler: EdsStateEventHandler = { event, _, ctx in
            guard let ctx else { return EdsError(EDS_ERR_OK) }
            let service = Unmanaged<CanonCameraService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                if event == 0x0000_0301 /* kEdsStateEvent_Shutdown */ {
                    service.handleDisconnect()
                }
            }
            return EdsError(EDS_ERR_OK)
        }
        EdsSetCameraStateEventHandler(cam, 0x0000_0300 /* kEdsStateEvent_All */, stateHandler, stateContext)

        // Register for object events (photo-taken notifications).
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handler: EdsObjectEventHandler = { event, ref, ctx in
            guard let ctx else { return EdsError(EDS_ERR_OK) }
            let service = Unmanaged<CanonCameraService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                service.handleObjectEvent(event, ref: ref)
            }
            return EdsError(EDS_ERR_OK)
        }
        EdsSetObjectEventHandler(cam, eventAll, handler, context)

        // SaveTo negotiation: Both/Host (newer bodies, direct-to-PC) → Camera (600D, card only).
        var accepted = false
        for var saveTo in [EdsUInt32(3 /* Both */), EdsUInt32(2 /* Host */)] {
            if EdsSetPropertyData(cam, propSaveTo, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &saveTo) == EDS_ERR_OK {
                // Host-saving needs capacity announced.
                EdsSendStatusCommand(cam, statusUILock, 0)
                var capacity = EdsCapacity(numberOfFreeClusters: 0x7FFFFFFF, bytesPerSector: 0x1000, reset: 1)
                EdsSetCapacity(cam, capacity)
                EdsSendStatusCommand(cam, statusUIUnlock, 0)
                accepted = true
                break
            }
        }
        if !accepted {
            var saveTo = EdsUInt32(1 /* Camera — 600D path, photos land on the SD card */)
            EdsSetPropertyData(cam, propSaveTo, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &saveTo)
        }

        isConnected = true
        showToast("\(cameraName ?? "Canon camera") has been connected")
        if evfEnabled {
            startEvf()
        }

        // Keep the body awake while connected (booths idle long enough for auto power-off).
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let service = CanonCameraService.shared
                if service.isConnected, let cam = service.camera {
                    EdsSendCommand(cam, service.cmdExtendShutDownTimer, 0)
                }
            }
        }
    }

    // MARK: Live view (EVF)

    private func startEvf() {
        guard let camera else { return }
        var mode: EdsUInt32 = 1
        EdsSetPropertyData(camera, propEvfMode, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &mode)
        var device: EdsUInt32 = evfOutputPC
        EdsSetPropertyData(camera, propEvfOutputDevice, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)

        evfTimer?.invalidate()
        evfTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                CanonCameraService.shared.downloadEvfFrame()
            }
        }
    }

    private func stopEvf() {
        evfTimer?.invalidate()
        evfTimer = nil
        guard let camera else { return }
        var device: EdsUInt32 = 0
        EdsSetPropertyData(camera, propEvfOutputDevice, 0, EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
    }

    private func downloadEvfFrame() {
        guard let camera else { return }
        var streamRef: EdsStreamRef?
        guard EdsCreateMemoryStream(0, &streamRef) == EDS_ERR_OK, let stream = streamRef else { return }
        defer { EdsRelease(stream) }

        var evfRef: EdsEvfImageRef?
        guard EdsCreateEvfImageRef(stream, &evfRef) == EDS_ERR_OK, let evf = evfRef else { return }
        defer { EdsRelease(evf) }

        // Fails harmlessly with OBJECT_NOTREADY until the camera starts streaming.
        guard EdsDownloadEvfImage(camera, evf) == EDS_ERR_OK else { return }

        var pointer: UnsafeMutableRawPointer?
        var length: EdsUInt64 = 0
        EdsGetPointer(stream, &pointer)
        EdsGetLength(stream, &length)
        guard let pointer, length > 0 else { return }

        let data = Data(bytes: pointer, count: Int(length))
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            evfImage = image
        }
    }

    // MARK: Capture

    /// Takes a photo and returns the full-resolution JPEG.
    /// RP path: camera pushes the file (DirItemRequestTransfer).
    /// 600D path: photo lands on the SD card; we detect it by comparing card contents
    /// against a snapshot taken just before the shutter.
    func capturePhoto() async throws -> Data {
        guard let camera, isConnected else {
            throw CanonError.notConnected
        }
        preShotFilenames = snapshotCardFilenames()

        let result = EdsSendCommand(camera, cmdTakePicture, 0)
        guard result == EDS_ERR_OK else {
            throw CanonError.shutterFailed(result)
        }

        return try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation

            // 600D safety net: if no object event ever arrives, scan the card anyway.
            cardScanFallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled, photoContinuation != nil else { return }
                self.scanCardForNewPhoto()
            }
            // Hard timeout: the 600D can take a while writing to a slow SD card.
            captureTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.finishCapture(.failure(CanonError.transferTimeout))
            }
        }
    }

    private func finishCapture(_ result: Result<Data, Error>) {
        captureTimeoutTask?.cancel()
        cardScanFallbackTask?.cancel()
        guard let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(with: result)
    }

    private func handleObjectEvent(_ event: EdsObjectEvent, ref: EdsBaseRef?) {
        switch event {
        case eventDirItemRequestTransfer:
            // Newer bodies (EOS RP): direct pull of the offered file.
            guard let ref else { return }
            if let data = downloadDirectoryItem(ref) {
                finishCapture(.success(data))
            }
            EdsRelease(ref)
        case eventDirItemCreated:
            // 600D: this ref is just a notification handle, not downloadable (err 0x61).
            // Give the camera time to finish writing, then scan the card.
            if let ref { EdsRelease(ref) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                self?.scanCardForNewPhoto()
            }
        default:
            break
        }
    }

    // MARK: Card scan (600D photo retrieval)

    private func scanCardForNewPhoto() {
        guard photoContinuation != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            // The 600D can take a couple of seconds to finish writing to a slow card.
            for _ in 0..<6 {
                if photoContinuation == nil { return }
                if let item = findNewCardItem() {
                    if let data = downloadDirectoryItem(item) {
                        EdsRelease(item)
                        finishCapture(.success(data))
                        return
                    }
                    EdsRelease(item)
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
            finishCapture(.failure(CanonError.photoNotFoundOnCard))
        }
    }

    /// Walks camera → volume → DCIM → subfolders and returns the first JPEG
    /// that wasn't on the card before the shutter. Caller releases the returned ref.
    private func findNewCardItem() -> EdsDirectoryItemRef? {
        var newest: EdsDirectoryItemRef?
        enumerateCardFiles { name, itemRef in
            if !preShotFilenames.contains(name), name.uppercased().hasSuffix(".JPG") {
                if let previous = newest { EdsRelease(previous) }
                EdsRetain(itemRef)
                newest = itemRef
            }
        }
        return newest
    }

    private func snapshotCardFilenames() -> Set<String> {
        var names: Set<String> = []
        enumerateCardFiles { name, _ in names.insert(name) }
        return names
    }

    /// Calls `visit` for every file in every DCIM subfolder of the first volume.
    private func enumerateCardFiles(_ visit: (String, EdsDirectoryItemRef) -> Void) {
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
                  itemName(folderInfo) == "DCIM" else { continue }

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
                        visit(itemName(fileInfo), file)
                    }
                    EdsRelease(file)
                }
            }
        }
    }

    private func downloadDirectoryItem(_ item: EdsBaseRef) -> Data? {
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

    private func itemName(_ info: EdsDirectoryItemInfo) -> String {
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
