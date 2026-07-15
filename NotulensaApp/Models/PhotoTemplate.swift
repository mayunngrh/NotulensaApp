import Foundation
import SwiftData
import CoreGraphics

@Model
final class PhotoTemplate {
    var name: String
    /// Fixed design space the editor and compositor work in.
    var canvasWidth: Double
    var canvasHeight: Double
    /// Relative path to the frame PNG (transparent cutouts).
    var frameImagePath: String
    /// Z-order of the frame PNG among the photo slots (higher = in front).
    var frameLayer: Int = 999
    /// Frame PNG placement on the canvas. Width 0 = not customized yet (use centered aspect-fit).
    var frameX: Double = 0
    var frameY: Double = 0
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    @Relationship(deleteRule: .cascade, inverse: \PhotoSlot.template)
    var slots: [PhotoSlot]
    var event: Event?

    init(name: String, frameImagePath: String, canvasWidth: Double = 1200, canvasHeight: Double = 1800) {
        self.name = name
        self.frameImagePath = frameImagePath
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.slots = []
    }

    /// Number of shots a session needs = highest photo index used by any slot.
    var shotCount: Int {
        slots.map(\.order).max() ?? 0
    }

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

    var sortedSlots: [PhotoSlot] {
        slots.sorted { $0.layer < $1.layer }
    }
}
