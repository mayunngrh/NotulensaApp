import Foundation
import SwiftData

@Model
final class PhotoSlot {
    /// 1-based index of the captured photo that fills this slot.
    var order: Int
    /// Position/size in canvas coordinates (top-left origin), rotation in degrees.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double
    /// Z-order among slots; the frame PNG is always drawn above all slots.
    var layer: Int
    var template: PhotoTemplate?

    init(order: Int, x: Double, y: Double, width: Double, height: Double, rotation: Double = 0, layer: Int = 0) {
        self.order = order
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
        self.layer = layer
    }
}
