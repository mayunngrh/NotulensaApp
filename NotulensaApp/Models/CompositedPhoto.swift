import Foundation
import Combine

/// One photobooth session's outputs: printable photo, MP4 slideshow, live photo,
/// the raw shots, and the public Drive link.
final class CompositedPhoto: ObservableObject, Identifiable, Codable {
    let id: UUID
    /// Relative path (under MediaStore.root) to the final printable JPEG.
    @Published var filePath: String
    /// Relative path to the live photo MP4 (looping slot clips in the template).
    @Published var livePhotoPath: String?
    /// Relative path to the MP4 slideshow of the captured photos.
    @Published var slideshowPath: String?
    /// Relative paths of the raw captured photos of this session.
    @Published var rawPhotoPaths: [String]
    /// Public Google Drive folder link for this session, once uploaded.
    @Published var driveURL: String?
    @Published var takenAt: Date

    init(filePath: String, livePhotoPath: String? = nil, slideshowPath: String? = nil) {
        self.id = UUID()
        self.filePath = filePath
        self.livePhotoPath = livePhotoPath
        self.slideshowPath = slideshowPath
        self.rawPhotoPaths = []
        self.takenAt = .now
    }

    enum CodingKeys: String, CodingKey {
        case id, filePath, livePhotoPath, slideshowPath, rawPhotoPaths, driveURL, takenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        filePath = try c.decode(String.self, forKey: .filePath)
        livePhotoPath = try c.decodeIfPresent(String.self, forKey: .livePhotoPath)
        slideshowPath = try c.decodeIfPresent(String.self, forKey: .slideshowPath)
        rawPhotoPaths = (try? c.decode([String].self, forKey: .rawPhotoPaths)) ?? []
        driveURL = try c.decodeIfPresent(String.self, forKey: .driveURL)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filePath, forKey: .filePath)
        try c.encodeIfPresent(livePhotoPath, forKey: .livePhotoPath)
        try c.encodeIfPresent(slideshowPath, forKey: .slideshowPath)
        try c.encode(rawPhotoPaths, forKey: .rawPhotoPaths)
        try c.encodeIfPresent(driveURL, forKey: .driveURL)
        try c.encode(takenAt, forKey: .takenAt)
    }
}
