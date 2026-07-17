import Foundation
import Combine
import SwiftUI
import AVFoundation

struct SessionResult {
    let printableURL: URL
    let slideshowURL: URL?
    let livePhotoURL: URL?
}

@MainActor
final class KioskViewModel: ObservableObject {
    enum State {
        case idle
        case welcome
        case gallery
        case pickCamera
        case pickTemplate
        case capturing
        case processing
        case result(SessionResult)
    }

    let event: Event
    let camera = CameraService()
    let canon = CanonCameraService.shared
    let sony = SonyCameraService.shared
    private let evfClipRecorder = EvfClipRecorder()
    private var cameraMonitors = Set<AnyCancellable>()

    enum LockedCamera {
        case canon
        case sony
        case webcam
    }

    /// Whichever camera was in use gets locked in for the rest of this kiosk launch —
    /// set once, on the first photo session. Prevents silently switching cameras
    /// mid-event if the other one happens to connect/disconnect later.
    @Published private(set) var lockedCamera: LockedCamera?

    var usesCanon: Bool { lockedCamera == .canon }
    var usesSony: Bool { lockedCamera == .sony }
    var usesWebcam: Bool { lockedCamera == .webcam || lockedCamera == nil }

    /// True while the locked-in camera is unavailable — blocks starting/continuing a
    /// countdown and surfaces the "camera disconnected" alert via errorMessage.
    private var lockedCameraAvailable: Bool {
        guard let lockedCamera else { return true }
        switch lockedCamera {
        case .canon: return canon.isConnected
        case .sony: return sony.isConnected
        case .webcam: return camera.isConnected
        }
    }
    private var lockedCameraName: String {
        switch lockedCamera {
        case .canon: return canon.cameraName ?? "Canon camera"
        case .sony: return sony.cameraName ?? "Sony camera"
        case .webcam, nil: return "Webcam"
        }
    }

    @Published var state: State = .pickCamera
    @Published var isInPreviewMode = false
    var template: PhotoTemplate?
    /// Captured JPEGs keyed by 1-based slot order.
    var shots: [Int: Data] = [:]
    /// Recorded video clip per slot order (for the live photo export).
    var clips: [Int: URL] = [:]
    @Published var currentOrder = 1
    /// nil = live preview, counting down when set; shot under review when reviewShot != nil.
    @Published var countdown: Int?
    @Published var reviewShot: Data?
    @Published var errorMessage: String?
    @Published var processingMessage: String = "Preparing your photos…"
    /// Set when a new result should be persisted into the event gallery.
    var pendingResultPath: String?
    var pendingLivePhotoPath: String?
    var pendingSlideshowPath: String?
    var pendingRawPaths: [String] = []

    // MARK: Google Drive upload
    enum UploadState {
        case idle
        case notSignedIn
        case uploading
        case done(URL)
        case failed(String)
    }
    @Published var uploadState: UploadState = .idle
    /// Public session-folder link — ready right after the session starts, before any upload.
    @Published var driveLink: URL?
    /// Drive folder link, persisted with the session record.
    var pendingDriveURL: String?

    private var captureTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    /// Resolves to the session folder ID; kicked off at session start so the QR is
    /// valid long before the outputs finish uploading.
    private var driveFolderTask: Task<String, Error>?

    init(event: Event) {
        self.event = event
        observeCameraDisconnects()
        observeGoogleSignIn()
    }

    /// If the user signs in to Google Drive *after* the session already started (the
    /// upfront prepareDriveFolder() call at startEvent() ran while signed out), create
    /// the session folder as soon as sign-in completes instead of waiting for the first
    /// upload attempt — this is what makes the QR code become valid right away.
    private func observeGoogleSignIn() {
        GoogleAuthService.shared.$isSignedIn
            .dropFirst()
            .sink { [weak self] signedIn in
                guard let self, signedIn, self.driveFolderTask == nil else { return }
                self.prepareDriveFolder()
            }
            .store(in: &cameraMonitors)
    }

    /// Watches whichever camera ends up locked in; if it disconnects mid-countdown,
    /// halt the capture and surface an alert instead of silently falling back to the
    /// other camera or failing the shutter with a confusing error.
    private func observeCameraDisconnects() {
        canon.$isConnected
            .dropFirst()
            .sink { [weak self] connected in
                guard let self, self.lockedCamera == .canon, !connected else { return }
                self.interruptForDisconnectedCamera()
            }
            .store(in: &cameraMonitors)
        sony.$isConnected
            .dropFirst()
            .sink { [weak self] connected in
                guard let self, self.lockedCamera == .sony, !connected else { return }
                self.interruptForDisconnectedCamera()
            }
            .store(in: &cameraMonitors)
        camera.$isConnected
            .dropFirst()
            .sink { [weak self] connected in
                guard let self, self.lockedCamera == .webcam, !connected else { return }
                self.interruptForDisconnectedCamera()
            }
            .store(in: &cameraMonitors)
    }

    private func interruptForDisconnectedCamera() {
        guard case .capturing = state else { return }
        captureTask?.cancel()
        reviewTask?.cancel()
        countdown = nil
        Task { _ = await stopClip() }
        errorMessage = "\(lockedCameraName) disconnected. Please reconnect it to continue this session."
    }

    // MARK: Flow — idle / welcome / gallery

    func showWelcome() {
        state = .welcome
    }

    func showGallery() {
        state = .gallery
    }

    func startSession() {
        shots = [:]
        clips = [:]
        currentOrder = 1
        reviewShot = nil
        errorMessage = nil
        uploadState = .idle
        driveLink = nil
        pendingDriveURL = nil
        prepareDriveFolder()
        // If camera already locked from initial launch, proceed to template/capture.
        // Otherwise, show camera picker first.
        if lockedCamera != nil {
            // Camera already selected; go straight to template picker or capture.
            if event.templates.count == 1 {
                template = event.templates[0]
                state = .capturing
                beginCountdown()
            } else {
                state = .pickTemplate
            }
        } else {
            // First time; show camera picker.
            state = .pickCamera
        }
    }

    func selectCamera(_ which: LockedCamera) {
        lockedCamera = which
        guard lockedCameraAvailable else {
            errorMessage = "\(lockedCameraName) is not connected. Please reconnect it before starting."
            return
        }
        // Wake/warm only the chosen camera and shut the others off — otherwise the webcam
        // (or the other DSLR's EVF) keeps streaming in the background and can bleed into
        // the preview.
        // Also stop the other cameras' background auto-detect polling so only the locked-in
        // camera's SDK stays active for the rest of the launch (one launch = one camera).
        switch which {
        case .canon:
            canon.wake()
            sony.setEvfEnabled(false)
            sony.stopMonitoring()
            camera.stop()
        case .sony:
            sony.wake()
            canon.setEvfEnabled(false)
            canon.stopMonitoring()
            camera.stop()
        case .webcam:
            camera.warm()
            canon.setEvfEnabled(false)
            canon.stopMonitoring()
            sony.setEvfEnabled(false)
            sony.stopMonitoring()
        }
        // Warm up the clip recorder encoder to avoid initialization stall during first countdown.
        evfClipRecorder.warmup()
        // Go to idle view after camera selection so user sees idle media before starting.
        state = .idle
    }

    func pick(_ template: PhotoTemplate) {
        self.template = template
        state = .capturing
        beginCountdown()
    }

    func startPreview() {
        isInPreviewMode = true
        shots.removeAll()
        clips.removeAll()
        // Matches startSession()'s numbering exactly — currentOrder is "the slot currently
        // being captured", 1-based, same as real capture. Preview reuses beginCountdown()/
        // retake()/next() below verbatim so it can never drift out of sync with
        // template.shotCount the way the old separate preview implementation did (that one
        // double-incremented currentOrder — once in previewNext(), again in its own capture
        // completion handler — which skipped slots and was the root cause of both the
        // "wrong slot" numbering and the freeze that showed up around the 3rd shot).
        currentOrder = 1
        reviewShot = nil
        countdown = nil
        errorMessage = nil

        // Use first template for preview
        guard let firstTemplate = event.templates.first else {
            errorMessage = "No templates available for preview."
            return
        }

        // No camera lock needed for preview — it's just a demo flow. Pick whichever
        // camera is actually connected: a connected DSLR means the webcam session was
        // already stopped (see KioskView.task), so blindly defaulting to .webcam here
        // would show a frozen/black feed. Fall back to webcam only when no DSLR is present.
        if lockedCamera == nil {
            if canon.isConnected {
                lockedCamera = .canon
            } else if sony.isConnected {
                lockedCamera = .sony
            } else {
                lockedCamera = .webcam
            }
        }
        NSLog("[Preview] startPreview() — lockedCamera=\(String(describing: lockedCamera)), canon.isConnected=\(canon.isConnected), canon.evfReady=\(canon.evfReady), sony.isConnected=\(sony.isConnected)")
        // Make sure the chosen camera's live feed is actually running for the preview.
        switch lockedCamera {
        case .canon: canon.setEvfEnabled(true); canon.wake()
        case .sony: sony.setEvfEnabled(true); sony.wake()
        case .webcam, nil: camera.warm()
        }

        template = firstTemplate
        state = .capturing
        // Wait for the camera's live feed to be ready before starting countdown —
        // gives the EVF frames time to warm up so the live photo capture has good initial frames.
        waitForCameraReady()
    }

    /// In preview mode: waits for the camera's live feed to be ready before starting
    /// the first countdown. Polls every 100ms until evfReady flips true.
    private func waitForCameraReady() {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let startTime = Date()
            while !Task.isCancelled {
                let isReady: Bool
                switch lockedCamera {
                case .canon: isReady = canon.evfReady
                case .sony: isReady = sony.evfReady
                case .webcam, nil: isReady = camera.isConnected
                }

                if isReady {
                    NSLog("[Preview] Camera ready, starting countdown")
                    beginCountdown()
                    return
                }

                // Timeout after 10 seconds to avoid infinite wait
                if Date().timeIntervalSince(startTime) > 10 {
                    NSLog("[Preview] Camera ready timeout, starting anyway")
                    beginCountdown()
                    return
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }


    // MARK: Capture

    func beginCountdown() {
        // Never start (or retry) a countdown on a locked-in camera that's currently
        // disconnected — surface the alert instead of shooting on the wrong camera.
        guard lockedCameraAvailable else {
            errorMessage = "\(lockedCameraName) disconnected. Please reconnect it to continue."
            return
        }
        // Warm up both cameras before every countdown: Canon reconnects if it dozed,
        // and webcam ensures the session stays running.
        canon.wake()
        camera.warm()
        reviewTask?.cancel()
        reviewShot = nil
        captureTask?.cancel()
        let seconds = event.countdown
        captureTask = Task { [weak self] in
            guard let self else { return }
            let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
            startClip(to: clipURL)
            for tick in stride(from: seconds, through: 1, by: -1) {
                countdown = tick
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    _ = await stopClip()
                    return
                }
            }
            countdown = nil
            // Stop the clip the moment the countdown ends — the live photo should be the
            // posing during the countdown only. Stopping after takePhoto() would append a
            // long frozen tail while the DSLR transfers the file (3–10s on the 600D).
            let recorded = await stopClip()
            do {
                NSLog(isInPreviewMode ? "[Preview] Taking photo \(currentOrder) of \(template?.shotCount ?? 0)" : "Taking photo \(currentOrder)")
                let data = try await takePhoto()
                shots[currentOrder] = data
                if let recorded {
                    clips[currentOrder] = recorded
                }
                reviewShot = data
                scheduleAutoAdvance()
            } catch {
                NSLog(isInPreviewMode ? "[Preview] Capture failed: \(error.localizedDescription)" : "Capture failed: \(error.localizedDescription)")
                errorMessage = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Camera source dispatch (Canon EDSDK / Sony CrSDK / Webcam)

    private func takePhoto() async throws -> Data {
        switch lockedCamera {
        case .canon:
            try await canon.capturePhoto()
        case .sony:
            try await sony.capturePhoto()
        case .webcam, nil:
            try await camera.capturePhoto()
        }
    }

    private func startClip(to url: URL) {
        switch lockedCamera {
        case .canon:
            let tap = evfClipRecorder.start(to: url)
            canon.frameTap = tap
        case .sony:
            let tap = evfClipRecorder.start(to: url)
            sony.frameTap = tap
        case .webcam, nil:
            camera.startRecording(to: url)
        }
    }

    private func stopClip() async -> URL? {
        switch lockedCamera {
        case .canon:
            canon.frameTap = nil
            return await evfClipRecorder.stop()
        case .sony:
            sony.frameTap = nil
            return await evfClipRecorder.stop()
        case .webcam, nil:
            return await camera.stopRecording()
        }
    }

    private func scheduleAutoAdvance() {
        // Preview mode waits for explicit Retake/Next taps — no auto-advance timer.
        // Real sessions auto-advance after the review display period.
        guard !isInPreviewMode else { return }
        reviewTask?.cancel()
        reviewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(event.reviewSeconds))
            if !Task.isCancelled { next() }
        }
    }

    func retake() {
        reviewTask?.cancel()
        if let clip = clips[currentOrder] { try? FileManager.default.removeItem(at: clip) }
        shots[currentOrder] = nil
        clips[currentOrder] = nil
        beginCountdown()
    }

    func next() {
        reviewTask?.cancel()
        guard let template else { return }
        if currentOrder < template.shotCount {
            currentOrder += 1
            beginCountdown()
        } else {
            // All slots filled — finish whether preview or real session. Preview goes to
            // the result page like a real session (user taps a button to return, no auto-timer).
            NSLog(isInPreviewMode ? "[Preview] All \(template.shotCount) preview photos taken, showing result" : "All \(template.shotCount) photos taken, finishing session")
            Task { await finishSession() }
        }
    }

    var isLastShot: Bool {
        guard let template else { return true }
        return currentOrder >= template.shotCount
    }

    // MARK: Finish — build all 3 outputs

    private func finishSession() async {
        guard let template else { return }
        state = .processing
        let eventID = event.id.uuidString
        let shotsSnapshot = shots
        let clipsSnapshot = clips
        let gifWidth = event.gifWidth
        let gifFrameSeconds = event.gifFrameSeconds
        let liveLoops = event.livePhotoLoops

        processingMessage = "Creating your printable photo…"
        guard let printablePath = try? Compositor.compose(template: template, photos: shotsSnapshot, eventID: eventID) else {
            errorMessage = "Could not create the final photo."
            backToWelcome()
            return
        }

        processingMessage = "Building your slideshow…"
        let slideshowPath = try? await SlideshowExporter.export(photos: shotsSnapshot, width: gifWidth, frameSeconds: gifFrameSeconds, loops: 2, eventID: eventID)

        var livePhotoPath: String?
        if !clipsSnapshot.isEmpty {
            processingMessage = "Rendering your live photo…"
            let snapshot = LivePhotoExporter.TemplateSnapshot(
                canvasWidth: template.canvasWidth,
                canvasHeight: template.canvasHeight,
                frameLayer: template.frameLayer,
                frameRect: frameRect(for: template),
                frameImagePath: template.frameImagePath,
                slots: template.slots.map {
                    .init(order: $0.order, x: $0.x, y: $0.y, width: $0.width, height: $0.height, rotation: $0.rotation, layer: $0.layer)
                }
            )
            livePhotoPath = try? await LivePhotoExporter.export(
                template: snapshot,
                clipsByOrder: clipsSnapshot,
                loops: liveLoops,
                eventID: eventID,
                expectedDuration: Double(event.countdown)
            )
        }

        for clip in clipsSnapshot.values { try? FileManager.default.removeItem(at: clip) }

        // Keep the raw shots as part of the session (locally + for the Drive upload).
        let stamp = Int(Date.now.timeIntervalSince1970)
        var rawPaths: [String] = []
        for (order, data) in shotsSnapshot.sorted(by: { $0.key < $1.key }) {
            if let path = try? MediaStore.write(data, into: .sessions, subfolder: eventID, fileName: "raw-\(stamp)-\(order).jpg") {
                rawPaths.append(path)
            }
        }

        pendingResultPath = printablePath
        pendingLivePhotoPath = livePhotoPath
        pendingSlideshowPath = slideshowPath
        pendingRawPaths = rawPaths
        pendingDriveURL = driveLink?.absoluteString
        state = .result(SessionResult(
            printableURL: MediaStore.url(for: printablePath),
            slideshowURL: slideshowPath.map { MediaStore.url(for: $0) },
            livePhotoURL: livePhotoPath.map { MediaStore.url(for: $0) }
        ))
        // Save results to gallery and upload to Google Drive — same as a normal session,
        // preview mode is no longer treated as a throwaway test flow.
        startUpload(printablePath: printablePath, livePhotoPath: livePhotoPath, slideshowPath: slideshowPath, rawPaths: rawPaths)
    }

    // MARK: Drive upload — folder created at session start (QR valid immediately),
    // files streamed into it in the background once the outputs exist.

    private var lastUploadArgs: (printable: String, live: String?, slideshow: String?, raw: [String])?

    /// Creates Master → Event → Session folders and makes the session folder public.
    /// Runs while the guest is still taking photos, so the QR never has to wait.
    private func prepareDriveFolder() {
        let auth = GoogleAuthService.shared
        driveFolderTask?.cancel()
        driveFolderTask = nil
        guard auth.isSignedIn else {
            NSLog("[Drive] prepareDriveFolder: not signed in, skipping")
            uploadState = .notSignedIn
            return
        }
        let eventName = event.name
        NSLog("[Drive] prepareDriveFolder: starting for event '\(eventName)'")
        driveFolderTask = Task { [weak self] in
            do {
                let token = try await auth.validAccessToken()
                NSLog("[Drive] Got access token")
                let drive = DriveUploader(accessToken: token)
                let rootID = try await drive.ensureFolder(name: auth.masterFolderName, parentID: nil)
                NSLog("[Drive] Root folder ID: \(rootID)")
                let eventFolderID = try await drive.ensureFolder(name: eventName, parentID: rootID)
                NSLog("[Drive] Event folder ID: \(eventFolderID)")
                let sessionName = Date.now.formatted(.dateTime.year().month().day().hour().minute().second())
                    .replacingOccurrences(of: "/", with: "-")
                let sessionID = try await drive.createFolder(name: "Session \(sessionName)", parentID: eventFolderID)
                NSLog("[Drive] Session folder created: \(sessionID)")
                try await drive.makePublic(fileID: sessionID)
                NSLog("[Drive] Session folder made public")

                let link = DriveUploader.folderLink(id: sessionID)
                NSLog("[Drive] QR link ready: \(link.absoluteString)")
                self?.driveLink = link
                self?.pendingDriveURL = link.absoluteString
                return sessionID
            } catch {
                NSLog("[Drive] prepareDriveFolder failed: \(error.localizedDescription)")
                throw error
            }
        }
    }

    func retryUpload() {
        guard let args = lastUploadArgs else { return }
        if driveLink == nil {
            prepareDriveFolder()
        }
        startUpload(printablePath: args.printable, livePhotoPath: args.live, slideshowPath: args.slideshow, rawPaths: args.raw)
    }

    private func startUpload(printablePath: String, livePhotoPath: String?, slideshowPath: String?, rawPaths: [String]) {
        lastUploadArgs = (printablePath, livePhotoPath, slideshowPath, rawPaths)
        let auth = GoogleAuthService.shared
        guard auth.isSignedIn else {
            NSLog("[Drive] startUpload: not signed in")
            uploadState = .notSignedIn
            return
        }
        // The folder is normally prepped upfront (prepareDriveFolder() at session start),
        // but that call is skipped if the user wasn't signed in yet at that moment — e.g.
        // they open Google Drive settings and sign in mid-session. Without this, the
        // upload would silently no-op forever because driveFolderTask stayed nil. Create
        // it lazily here so signing in at any point during the session still uploads.
        if driveFolderTask == nil {
            NSLog("[Drive] startUpload: no folder task yet, creating it now")
            prepareDriveFolder()
        }
        guard let folderTask = driveFolderTask else {
            NSLog("[Drive] startUpload: still no folder task after retry")
            uploadState = .notSignedIn
            return
        }
        NSLog("[Drive] startUpload: starting (printable, slideshow=\(slideshowPath != nil), livePhoto=\(livePhotoPath != nil), raw=\(rawPaths.count))")
        uploadState = .uploading
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            do {
                let sessionID = try await folderTask.value
                NSLog("[Drive] Got session ID: \(sessionID)")
                let token = try await auth.validAccessToken()
                let drive = DriveUploader(accessToken: token)

                var files: [(String, String, String)] = [(printablePath, "printable.jpg", "image/jpeg")]
                if let slideshowPath { files.append((slideshowPath, "slideshow.mp4", "video/mp4")) }
                if let livePhotoPath { files.append((livePhotoPath, "livephoto.mp4", "video/mp4")) }
                for (index, raw) in rawPaths.enumerated() {
                    files.append((raw, "photo-\(index + 1).jpg", "image/jpeg"))
                }
                NSLog("[Drive] Uploading \(files.count) files...")
                for (relPath, name, mime) in files {
                    NSLog("[Drive] Uploading: \(name)")
                    try await drive.upload(fileURL: MediaStore.url(for: relPath), as: name, mimeType: mime, parentID: sessionID)
                    NSLog("[Drive] ✓ Uploaded: \(name)")
                }
                let finalLink = DriveUploader.folderLink(id: sessionID)
                NSLog("[Drive] Upload complete: \(finalLink.absoluteString)")
                self?.uploadState = .done(finalLink)
            } catch {
                if !Task.isCancelled {
                    NSLog("[Drive] Upload failed: \(error.localizedDescription)")
                    self?.uploadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func frameRect(for template: PhotoTemplate) -> CGRect {
        let imageSize = NSImage(contentsOf: MediaStore.url(for: template.frameImagePath))?.size ?? .zero
        return template.frameRect(imageSize: imageSize)
    }

    func backToWelcome() {
        captureTask?.cancel()
        reviewTask?.cancel()
        isInPreviewMode = false
        countdown = nil
        reviewShot = nil
        template = nil
        shots = [:]
        clips = [:]
        state = .welcome
    }

    func backToIdle() {
        captureTask?.cancel()
        reviewTask?.cancel()
        isInPreviewMode = false
        countdown = nil
        reviewShot = nil
        template = nil
        shots = [:]
        clips = [:]
        state = .idle
    }
}
