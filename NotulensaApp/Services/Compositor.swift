import Foundation
import AppKit
import CoreGraphics

/// Composites captured photos into a template: slots sorted by layer, each photo
/// cover-fit and rotated about its slot center, frame PNG at its own layer/rect.
enum Compositor {
    /// `photos[order]` = captured JPEG for that 1-based slot order.
    /// Returns the relative path of the exported JPEG (long edge ≈ 3600 px for print).
    static func compose(template: PhotoTemplate, photos: [Int: Data], eventID: String) throws -> String {
        let scale = min(2.0, 3600.0 / max(template.canvasWidth, template.canvasHeight))
        var images: [Int: CGImage] = [:]
        for (order, data) in photos {
            images[order] = cgImage(from: data)
        }
        guard let output = render(template: template, images: images, scale: scale) else {
            throw CompositorError.exportFailed
        }
        let rep = NSBitmapImageRep(cgImage: output)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw CompositorError.exportFailed
        }
        let fileName = "result-\(Int(Date.now.timeIntervalSince1970)).jpg"
        return try MediaStore.write(jpeg, into: .sessions, subfolder: eventID, fileName: fileName)
    }

    /// Renders one composited frame at `canvas * scale` pixels. Used for the printable
    /// photo and per-frame by the live photo exporter (with video frames as images).
    static func render(template: PhotoTemplate, images: [Int: CGImage], scale: Double) -> CGImage? {
        let canvasW = template.canvasWidth
        let canvasH = template.canvasHeight
        let outW = Int(canvasW * scale)
        let outH = Int(canvasH * scale)

        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGContext origin is bottom-left; template coords are top-left. Flip once.
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: scale, y: -scale)

        // Black canvas: non-4R frames are letterboxed onto it, keeping their aspect ratio.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        for slot in template.sortedSlots where slot.layer < template.frameLayer {
            guard let photo = images[slot.order] else { continue }
            draw(photo: photo, in: slot, context: ctx)
        }

        if let frame = cgImage(from: MediaStore.url(for: template.frameImagePath)) {
            drawTopLeft(frame, in: template.frameRect(imageSize: CGSize(width: frame.width, height: frame.height)), context: ctx)
        }

        for slot in template.sortedSlots where slot.layer >= template.frameLayer {
            guard let photo = images[slot.order] else { continue }
            draw(photo: photo, in: slot, context: ctx)
        }

        return ctx.makeImage()
    }

    private static func draw(photo: CGImage, in slot: PhotoSlot, context ctx: CGContext) {
        ctx.saveGState()
        let center = CGPoint(x: slot.x + slot.width / 2, y: slot.y + slot.height / 2)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: slot.rotation * .pi / 180)

        let slotRect = CGRect(x: -slot.width / 2, y: -slot.height / 2, width: slot.width, height: slot.height)
        ctx.clip(to: slotRect)

        // Cover-fit: scale so the photo fills the slot, cropping the overflow.
        let photoW = CGFloat(photo.width), photoH = CGFloat(photo.height)
        let fit = max(slot.width / photoW, slot.height / photoH)
        let drawRect = CGRect(
            x: -photoW * fit / 2, y: -photoH * fit / 2,
            width: photoW * fit, height: photoH * fit
        )
        drawTopLeft(photo, in: drawRect, context: ctx)
        ctx.restoreGState()
    }

    /// CGContext.draw is bottom-up; our context is flipped to top-left coords,
    /// so un-flip locally around the target rect to avoid drawing images upside down.
    private static func drawTopLeft(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func cgImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    enum CompositorError: Error {
        case contextFailed
        case exportFailed
    }
}
