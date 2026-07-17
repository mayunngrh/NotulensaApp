import Foundation
import Combine
import CoreGraphics

final class PhotoTemplate: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID

    static func == (lhs: PhotoTemplate, rhs: PhotoTemplate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    @Published var name: String
    /// Fixed design space the editor and compositor work in.
    @Published var canvasWidth: Double
    @Published var canvasHeight: Double
    /// Relative path to the frame PNG (transparent cutouts).
    @Published var frameImagePath: String
    /// Z-order of the frame PNG among the photo slots (higher = in front).
    @Published var frameLayer: Int
    /// Frame PNG placement on the canvas. Width 0 = not customized yet (centered aspect-fit).
    @Published var frameX: Double
    @Published var frameY: Double
    @Published var frameWidth: Double
    @Published var frameHeight: Double
    @Published var slots: [PhotoSlot]

    init(name: String, frameImagePath: String, canvasWidth: Double = 1200, canvasHeight: Double = 1800) {
        self.id = UUID()
        self.name = name
        self.frameImagePath = frameImagePath
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameLayer = 999
        self.frameX = 0
        self.frameY = 0
        self.frameWidth = 0
        self.frameHeight = 0
        self.slots = []
    }

    /// Number of shots a session needs = highest photo index used by any slot.
    var shotCount: Int { slots.map(\.order).max() ?? 0 }

    /// Where the frame PNG sits on the canvas: the stored rect, or centered aspect-fit by default.
    func frameRect(imageSize: CGSize) -> CGRect {
        if frameWidth > 0 {
            return CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)
        }
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        }
        let scale = min(canvasWidth / imageSize.width, canvasHeight / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (canvasWidth - w) / 2, y: (canvasHeight - h) / 2, width: w, height: h)
    }

    var sortedSlots: [PhotoSlot] { slots.sorted { $0.layer < $1.layer } }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, name, canvasWidth, canvasHeight, frameImagePath
        case frameLayer, frameX, frameY, frameWidth, frameHeight, slots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        canvasWidth = try c.decode(Double.self, forKey: .canvasWidth)
        canvasHeight = try c.decode(Double.self, forKey: .canvasHeight)
        frameImagePath = try c.decode(String.self, forKey: .frameImagePath)
        frameLayer = (try? c.decode(Int.self, forKey: .frameLayer)) ?? 999
        frameX = (try? c.decode(Double.self, forKey: .frameX)) ?? 0
        frameY = (try? c.decode(Double.self, forKey: .frameY)) ?? 0
        frameWidth = (try? c.decode(Double.self, forKey: .frameWidth)) ?? 0
        frameHeight = (try? c.decode(Double.self, forKey: .frameHeight)) ?? 0
        slots = (try? c.decode([PhotoSlot].self, forKey: .slots)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(canvasWidth, forKey: .canvasWidth)
        try c.encode(canvasHeight, forKey: .canvasHeight)
        try c.encode(frameImagePath, forKey: .frameImagePath)
        try c.encode(frameLayer, forKey: .frameLayer)
        try c.encode(frameX, forKey: .frameX)
        try c.encode(frameY, forKey: .frameY)
        try c.encode(frameWidth, forKey: .frameWidth)
        try c.encode(frameHeight, forKey: .frameHeight)
        try c.encode(slots, forKey: .slots)
    }
}
