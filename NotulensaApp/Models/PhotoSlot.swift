import Foundation
import Combine

final class PhotoSlot: ObservableObject, Identifiable, Codable, Equatable {
    let id: UUID

    static func == (lhs: PhotoSlot, rhs: PhotoSlot) -> Bool { lhs.id == rhs.id }
    /// 1-based index of the captured photo that fills this slot.
    @Published var order: Int
    /// Position/size in canvas coordinates (top-left origin), rotation in degrees.
    @Published var x: Double
    @Published var y: Double
    @Published var width: Double
    @Published var height: Double
    @Published var rotation: Double
    /// Z-order among slots; the frame PNG has its own frameLayer.
    @Published var layer: Int

    init(order: Int, x: Double, y: Double, width: Double, height: Double, rotation: Double = 0, layer: Int = 0) {
        self.id = UUID()
        self.order = order
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.layer = layer
    }

    enum CodingKeys: String, CodingKey {
        case id, order, x, y, width, height, rotation, layer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        order = try c.decode(Int.self, forKey: .order)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        layer = (try? c.decode(Int.self, forKey: .layer)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(order, forKey: .order)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(layer, forKey: .layer)
    }
}
