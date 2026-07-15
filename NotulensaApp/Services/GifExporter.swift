import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Builds a looping animated GIF from the captured photos of one session.
enum GifExporter {
    /// `photos[order]` = captured JPEG per shot. Returns the relative path of the GIF.
    static func export(photos: [Int: Data], width: Int, frameSeconds: Double, eventID: String) throws -> String {
        let frames = photos.sorted { $0.key < $1.key }.compactMap { Compositor.cgImage(from: $0.value) }
        guard !frames.isEmpty else { throw ExportError.noFrames }

        let fileName = "gif-\(Int(Date.now.timeIntervalSince1970)).gif"
        let dir = MediaStore.directory(.sessions).appendingPathComponent(eventID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ExportError.encodingFailed
        }
        let gifProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0] // loop forever
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameSeconds]
        ] as CFDictionary

        for frame in frames {
            let resized = resize(frame, toWidth: width) ?? frame
            CGImageDestinationAddImage(destination, resized, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        return "\(MediaStore.Folder.sessions.rawValue)/\(eventID)/\(fileName)"
    }

    private static func resize(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = Int(Double(width) * Double(image.height) / Double(image.width))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    enum ExportError: Error {
        case noFrames
        case encodingFailed
    }
}
