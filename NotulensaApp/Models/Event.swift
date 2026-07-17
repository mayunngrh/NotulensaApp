import Foundation
import Combine

/// One photobooth event. Ventura-compatible: plain ObservableObject persisted as JSON
/// by PhotoboothStore (SwiftData needs macOS 14; this runs on macOS 13+).
final class Event: ObservableObject, Identifiable, Codable {
    let id: UUID
    @Published var name: String
    @Published var createdAt: Date

    // MARK: Idle & welcome screen
    @Published var idleMediaPath: String?
    @Published var welcomeBackgroundPath: String?
    @Published var startButtonRelX: Double
    @Published var startButtonRelY: Double
    @Published var galleryButtonRelX: Double
    @Published var galleryButtonRelY: Double

    // MARK: Capture settings
    @Published var cameraSource: String
    @Published var countdown: Int
    @Published var reviewSeconds: Int

    // MARK: Slideshow settings (kept "gif" names for storage compatibility)
    @Published var gifWidth: Int
    @Published var gifFrameSeconds: Double

    // MARK: Live photo settings
    @Published var livePhotoLoops: Int
    @Published var enablePreview: Bool

    @Published var templates: [PhotoTemplate]
    @Published var captures: [CompositedPhoto]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.idleMediaPath = nil
        self.welcomeBackgroundPath = nil
        self.startButtonRelX = 0.5
        self.startButtonRelY = 0.72
        self.galleryButtonRelX = 0.5
        self.galleryButtonRelY = 0.86
        self.cameraSource = "webcam"
        self.countdown = 5
        self.reviewSeconds = 5
        self.gifWidth = 720
        self.gifFrameSeconds = 0.8
        self.livePhotoLoops = 2
        self.enablePreview = false
        self.templates = []
        self.captures = []
    }

    var idleMediaIsVideo: Bool {
        guard let path = idleMediaPath else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext)
    }

    /// Ready to launch / finish setup: at least one template, and every template has
    /// at least one photo slot (an empty template would break the capture flow).
    var canStart: Bool {
        !templates.isEmpty && templates.allSatisfy { $0.shotCount >= 1 }
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, idleMediaPath, welcomeBackgroundPath
        case startButtonRelX, startButtonRelY, galleryButtonRelX, galleryButtonRelY
        case cameraSource, countdown, countdownFirst, countdownOthers, reviewSeconds
        case gifWidth, gifFrameSeconds, livePhotoLoops, enablePreview, templates, captures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        idleMediaPath = try c.decodeIfPresent(String.self, forKey: .idleMediaPath)
        welcomeBackgroundPath = try c.decodeIfPresent(String.self, forKey: .welcomeBackgroundPath)
        startButtonRelX = (try? c.decode(Double.self, forKey: .startButtonRelX)) ?? 0.5
        startButtonRelY = (try? c.decode(Double.self, forKey: .startButtonRelY)) ?? 0.72
        galleryButtonRelX = (try? c.decode(Double.self, forKey: .galleryButtonRelX)) ?? 0.5
        galleryButtonRelY = (try? c.decode(Double.self, forKey: .galleryButtonRelY)) ?? 0.86
        cameraSource = (try? c.decode(String.self, forKey: .cameraSource)) ?? "webcam"
        countdown = (try? c.decode(Int.self, forKey: .countdown)) ?? (try? c.decode(Int.self, forKey: .countdownFirst)) ?? 5
        reviewSeconds = (try? c.decode(Int.self, forKey: .reviewSeconds)) ?? 5
        gifWidth = (try? c.decode(Int.self, forKey: .gifWidth)) ?? 720
        gifFrameSeconds = (try? c.decode(Double.self, forKey: .gifFrameSeconds)) ?? 0.8
        livePhotoLoops = (try? c.decode(Int.self, forKey: .livePhotoLoops)) ?? 2
        enablePreview = (try? c.decode(Bool.self, forKey: .enablePreview)) ?? false
        templates = (try? c.decode([PhotoTemplate].self, forKey: .templates)) ?? []
        captures = (try? c.decode([CompositedPhoto].self, forKey: .captures)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(idleMediaPath, forKey: .idleMediaPath)
        try c.encodeIfPresent(welcomeBackgroundPath, forKey: .welcomeBackgroundPath)
        try c.encode(startButtonRelX, forKey: .startButtonRelX)
        try c.encode(startButtonRelY, forKey: .startButtonRelY)
        try c.encode(galleryButtonRelX, forKey: .galleryButtonRelX)
        try c.encode(galleryButtonRelY, forKey: .galleryButtonRelY)
        try c.encode(cameraSource, forKey: .cameraSource)
        try c.encode(countdown, forKey: .countdown)
        try c.encode(reviewSeconds, forKey: .reviewSeconds)
        try c.encode(gifWidth, forKey: .gifWidth)
        try c.encode(gifFrameSeconds, forKey: .gifFrameSeconds)
        try c.encode(livePhotoLoops, forKey: .livePhotoLoops)
        try c.encode(enablePreview, forKey: .enablePreview)
        try c.encode(templates, forKey: .templates)
        try c.encode(captures, forKey: .captures)
    }
}
