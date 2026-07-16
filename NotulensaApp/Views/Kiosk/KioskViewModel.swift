import Foundation
import SwiftUI
import SwiftData
import AVFoundation

struct SessionResult {
    let printableURL: URL
    let gifURL: URL?
    let livePhotoURL: URL?
}

@Observable
@MainActor
final class KioskViewModel {
    enum State {
        case idle
        case welcome
        case gallery
        case pickTemplate
        case capturing
        case processing
        case result(SessionResult)
    }

    let event: Event
    let camera = CameraService()

    var state: State = .idle
    var template: PhotoTemplate?
    /// Captured JPEGs keyed by 1-based slot order.
    var shots: [Int: Data] = [:]
    /// Recorded video clip per slot order (for the live photo export).
    var clips: [Int: URL] = [:]
    var currentOrder = 1
    /// nil = live preview, counting down when set; shot under review when reviewShot != nil.
    var countdown: Int?
    var reviewShot: Data?
    var errorMessage: String?
    var processingMessage: String = "Preparing your photos…"
    /// Set when a new result should be persisted into the event gallery.
    var pendingResultPath: String?
    var pendingGifPath: String?
    var pendingLivePhotoPath: String?
    var pendingRawPaths: [String] = []

    // MARK: Google Drive upload
    enum UploadState {
        case idle
        case notSignedIn
        case uploading
        case done(URL)
        case failed(String)
    }
    var uploadState: UploadState = .idle
    /// Public session-folder link — ready right after the session starts, before any upload.
    var driveLink: URL?
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
        if event.templates.count == 1 {
            template = event.templates[0]
            state = .capturing
            beginCountdown()
        } else {
            state = .pickTemplate
        }
    }

    func pick(_ template: PhotoTemplate) {
        self.template = template
        state = .capturing
        beginCountdown()
    }

    // MARK: Capture

    func beginCountdown() {
        reviewTask?.cancel()
        reviewShot = nil
        captureTask?.cancel()
        let seconds = currentOrder == 1 ? event.countdownFirst : event.countdownOthers
        captureTask = Task { [weak self] in
            guard let self else { return }
            let clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
            camera.startRecording(to: clipURL)
            for tick in stride(from: seconds, through: 1, by: -1) {
                countdown = tick
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    _ = await camera.stopRecording()
                    return
                }
            }
            countdown = nil
            do {
                async let photoTask = camera.capturePhoto()
                let data = try await photoTask
                shots[currentOrder] = data
                if let recorded = await camera.stopRecording() {
                    clips[currentOrder] = recorded
                }
                reviewShot = data
                scheduleAutoAdvance()
            } catch {
                _ = await camera.stopRecording()
                errorMessage = "Capture failed: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleAutoAdvance() {
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
        let eventID = event.persistentModelID.hashValue.description
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

        processingMessage = "Building your GIF…"
        let gifPath = try? GifExporter.export(photos: shotsSnapshot, width: gifWidth, frameSeconds: gifFrameSeconds, eventID: eventID)

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
            livePhotoPath = try? await LivePhotoExporter.export(template: snapshot, clipsByOrder: clipsSnapshot, loops: liveLoops, eventID: eventID)
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
        pendingGifPath = gifPath
        pendingLivePhotoPath = livePhotoPath
        pendingRawPaths = rawPaths
        pendingDriveURL = nil
        state = .result(SessionResult(
            printableURL: MediaStore.url(for: printablePath),
            gifURL: gifPath.map { MediaStore.url(for: $0) },
            livePhotoURL: livePhotoPath.map { MediaStore.url(for: $0) }
        ))
        startUpload(printablePath: printablePath, gifPath: gifPath, livePhotoPath: livePhotoPath, rawPaths: rawPaths)
    }

    // MARK: Drive upload — folder created at session start (QR valid immediately),
    // files streamed into it in the background once the outputs exist.

    private var lastUploadArgs: (printable: String, gif: String?, live: String?, raw: [String])?

    /// Creates Master → Event → Session folders and makes the session folder public.
    /// Runs while the guest is still taking photos, so the QR never has to wait.
    private func prepareDriveFolder() {
        let auth = GoogleAuthService.shared
        driveFolderTask?.cancel()
        driveFolderTask = nil
        guard auth.isSignedIn else {
            uploadState = .notSignedIn
            return
        }
        let eventName = event.name
        driveFolderTask = Task { [weak self] in
            let token = try await auth.validAccessToken()
            let drive = DriveUploader(accessToken: token)
            let rootID = try await drive.ensureFolder(name: auth.masterFolderName, parentID: nil)
            let eventFolderID = try await drive.ensureFolder(name: eventName, parentID: rootID)
            let sessionName = Date.now.formatted(.dateTime.year().month().day().hour().minute().second())
                .replacingOccurrences(of: "/", with: "-")
            let sessionID = try await drive.createFolder(name: "Session \(sessionName)", parentID: eventFolderID)
            try await drive.makePublic(fileID: sessionID)

            let link = DriveUploader.folderLink(id: sessionID)
            self?.driveLink = link
            self?.pendingDriveURL = link.absoluteString
            return sessionID
        }
    }

    func retryUpload() {
        guard let args = lastUploadArgs else { return }
        if driveLink == nil {
            prepareDriveFolder()
        }
        startUpload(printablePath: args.printable, gifPath: args.gif, livePhotoPath: args.live, rawPaths: args.raw)
    }

    private func startUpload(printablePath: String, gifPath: String?, livePhotoPath: String?, rawPaths: [String]) {
        lastUploadArgs = (printablePath, gifPath, livePhotoPath, rawPaths)
        let auth = GoogleAuthService.shared
        guard auth.isSignedIn, let folderTask = driveFolderTask else {
            uploadState = .notSignedIn
            return
        }
        uploadState = .uploading
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            do {
                let sessionID = try await folderTask.value
                let token = try await auth.validAccessToken()
                let drive = DriveUploader(accessToken: token)

                var files: [(String, String, String)] = [(printablePath, "printable.jpg", "image/jpeg")]
                if let gifPath { files.append((gifPath, "animation.gif", "image/gif")) }
                if let livePhotoPath { files.append((livePhotoPath, "livephoto.mov", "video/quicktime")) }
                for (index, raw) in rawPaths.enumerated() {
                    files.append((raw, "photo-\(index + 1).jpg", "image/jpeg"))
                }
                for (relPath, name, mime) in files {
                    try await drive.upload(fileURL: MediaStore.url(for: relPath), as: name, mimeType: mime, parentID: sessionID)
                }
                self?.uploadState = .done(DriveUploader.folderLink(id: sessionID))
            } catch {
                if !Task.isCancelled {
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
        countdown = nil
        reviewShot = nil
        template = nil
        shots = [:]
        clips = [:]
        state = .idle
    }
}
