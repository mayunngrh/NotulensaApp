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

    private var captureTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?

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

        pendingResultPath = printablePath
        pendingGifPath = gifPath
        pendingLivePhotoPath = livePhotoPath
        state = .result(SessionResult(
            printableURL: MediaStore.url(for: printablePath),
            gifURL: gifPath.map { MediaStore.url(for: $0) },
            livePhotoURL: livePhotoPath.map { MediaStore.url(for: $0) }
        ))
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
