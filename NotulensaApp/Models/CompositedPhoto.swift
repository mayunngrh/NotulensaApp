import Foundation
import SwiftData

/// One photobooth session's outputs: printable photo, MP4 slideshow, live photo,
/// the raw shots, and the public Drive link.
@Model
final class CompositedPhoto {
    /// Relative path (under MediaStore.root) to the final printable JPEG.
    var filePath: String
    /// Relative path to the live photo MP4 (looping slot clips in the template).
    var livePhotoPath: String?
    /// Relative path to the MP4 slideshow of the captured photos.
    var slideshowPath: String?
    /// Relative paths of the raw captured photos of this session.
    var rawPhotoPaths: [String] = []
    /// Public Google Drive folder link for this session, once uploaded.
    var driveURL: String?
    var takenAt: Date
    var event: Event?

    init(filePath: String, livePhotoPath: String? = nil, slideshowPath: String? = nil) {
        self.filePath = filePath
        self.livePhotoPath = livePhotoPath
        self.slideshowPath = slideshowPath
        self.takenAt = .now
    }
}
