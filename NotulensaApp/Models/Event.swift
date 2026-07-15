import Foundation
import SwiftData

@Model
final class Event {
    var name: String
    var createdAt: Date

    // MARK: Idle & welcome screen
    /// Relative path to the idle video/photo shown when nothing happens.
    var idleMediaPath: String?
    /// Relative path to the welcome screen background photo.
    var welcomeBackgroundPath: String?
    /// Welcome screen button positions, relative (0...1) to the screen.
    var startButtonRelX: Double = 0.5
    var startButtonRelY: Double = 0.72
    var galleryButtonRelX: Double = 0.5
    var galleryButtonRelY: Double = 0.86

    // MARK: Capture settings
    /// Countdown seconds before the first photo.
    var countdownFirst: Int = 5
    /// Countdown seconds before the remaining photos.
    var countdownOthers: Int = 3
    /// How long each captured photo is displayed for review before auto-continuing.
    var reviewSeconds: Int = 5

    // MARK: GIF settings
    /// Output GIF width in pixels.
    var gifWidth: Int = 720
    /// Seconds each photo is shown in the GIF.
    var gifFrameSeconds: Double = 0.8

    // MARK: Live photo settings
    /// How many times the slot clips loop in the live photo video.
    var livePhotoLoops: Int = 2

    @Relationship(deleteRule: .cascade, inverse: \PhotoTemplate.event)
    var templates: [PhotoTemplate]
    @Relationship(deleteRule: .cascade, inverse: \CompositedPhoto.event)
    var captures: [CompositedPhoto]

    init(name: String) {
        self.name = name
        self.createdAt = .now
        self.idleMediaPath = nil
        self.templates = []
        self.captures = []
    }

    var idleMediaIsVideo: Bool {
        guard let path = idleMediaPath else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext)
    }

    var canStart: Bool {
        !templates.isEmpty
    }
}
