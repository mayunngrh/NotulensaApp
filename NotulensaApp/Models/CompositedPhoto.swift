import Foundation
import SwiftData

@Model
final class CompositedPhoto {
    /// Relative path (under MediaStore.root) to the final printable JPEG.
    var filePath: String
    /// Relative path to the animated GIF made from the captured photos.
    var gifPath: String?
    /// Relative path to the live photo video (looping slot clips in the template).
    var livePhotoPath: String?
    /// Relative paths of the raw captured photos of this session.
    var rawPhotoPaths: [String] = []
    /// Public Google Drive folder link for this session, once uploaded.
    var driveURL: String?
    var takenAt: Date
    var event: Event?

    init(filePath: String, gifPath: String? = nil, livePhotoPath: String? = nil) {
        self.filePath = filePath
        self.gifPath = gifPath
        self.livePhotoPath = livePhotoPath
        self.takenAt = .now
    }
}
