import Foundation
import AVFoundation
import CoreGraphics
import AppKit

/// Builds a looping "live photo" video: each slot's recorded clip is composited into the
/// template every frame (same layout as the printable photo), then the whole sequence
/// loops `loops` times. No ffmpeg dependency — AVAssetWriter covers encoding natively.
enum LivePhotoExporter {
    struct SlotSnapshot: Sendable {
        let order: Int
        let x, y, width, height, rotation: Double
        let layer: Int
    }

    struct TemplateSnapshot: Sendable {
        let canvasWidth: Double
        let canvasHeight: Double
        let frameLayer: Int
        let frameRect: CGRect
        let frameImagePath: String
        let slots: [SlotSnapshot]
    }

    /// Match the recorded clip rate (30fps) to avoid frame skipping, which reads as jank
    /// even if individual frames are rendered cleanly.
    static let fps: Int32 = 30

    /// `expectedDuration` is the countdown length every clip was *supposed* to record
    /// (in seconds) — passed in rather than measured per-clip. Real recordings vary by
    /// a few milliseconds due to task-scheduling jitter, so deriving frame count from
    /// each clip's actual duration (or worse, the shortest one) made every shot's output
    /// length slightly different and truncated longer clips. Using one shared constant
    /// makes every slot's frame count and duration identical, down to the frame — any
    /// clip that runs a hair short just holds its last frame (already handled below)
    /// instead of the whole export being clipped to the shortest recording.
    static func export(template: TemplateSnapshot, clipsByOrder: [Int: URL], loops: Int, eventID: String, expectedDuration: Double) async throws -> String {
        guard !clipsByOrder.isEmpty, expectedDuration > 0 else {
            throw ExportError.noClips
        }
        let assets = clipsByOrder.mapValues { AVURLAsset(url: $0) }
        var generators: [Int: AVAssetImageGenerator] = [:]
        for (order, asset) in assets {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            // Use moderate tolerance (33ms = 1 frame at 30fps) to handle timing jitter
            // without snapping too far to wrong keyframes.
            let tolerance = CMTime(seconds: 1.0 / Double(fps), preferredTimescale: 600)
            gen.requestedTimeToleranceBefore = tolerance
            gen.requestedTimeToleranceAfter = tolerance
            generators[order] = gen
        }
        // Always extract at 30fps for consistent output timing, for exactly the countdown
        // length — identical for every slot regardless of each clip's actual recorded length.
        let frameCount = max(1, Int(expectedDuration * Double(fps)))

        let scale = min(1.0, 1080.0 / max(template.canvasWidth, template.canvasHeight))
        let outW = Int(template.canvasWidth * scale)
        let outH = Int(template.canvasHeight * scale)

        let fileName = "live-\(Int(Date.now.timeIntervalSince1970)).mp4"
        let dir = MediaStore.directory(.sessions).appendingPathComponent(eventID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outputURL = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: NSNumber(value: fps)
            ] as [String: Any]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameImage = Compositor.cgImage(from: MediaStore.url(for: template.frameImagePath))
        // Fallback for any frame a slot still fails to decode: reuse its last good frame
        // rather than leaving it blank, so nothing ever pops in/out or flashes black.
        var lastGoodFrame: [Int: CGImage] = [:]

        for loop in 0..<max(1, loops) {
            for frameIndex in 0..<frameCount {
                let time = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
                var images: [Int: CGImage] = [:]
                for (order, gen) in generators {
                    if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                        images[order] = cg
                        lastGoodFrame[order] = cg
                    } else if let held = lastGoodFrame[order] {
                        images[order] = held
                    }
                }
                guard let composited = renderFrame(template: template, images: images, frame: frameImage, scale: scale, outW: outW, outH: outH),
                      let buffer = pixelBuffer(from: composited, width: outW, height: outH) else { continue }

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let pts = CMTime(value: CMTimeValue((loop * frameCount + frameIndex)), timescale: fps)
                adaptor.append(buffer, withPresentationTime: pts)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        return "\(MediaStore.Folder.sessions.rawValue)/\(eventID)/\(fileName)"
    }

    private static func renderFrame(template: TemplateSnapshot, images: [Int: CGImage], frame: CGImage?, scale: Double, outW: Int, outH: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: template.canvasWidth, height: template.canvasHeight))

        let below = template.slots.filter { $0.layer < template.frameLayer }
        let above = template.slots.filter { $0.layer >= template.frameLayer }

        for slot in below {
            guard let photo = images[slot.order] else { continue }
            draw(photo, slot: slot, context: ctx)
        }
        if let frame {
            drawTopLeft(frame, in: template.frameRect, context: ctx)
        }
        for slot in above {
            guard let photo = images[slot.order] else { continue }
            draw(photo, slot: slot, context: ctx)
        }
        return ctx.makeImage()
    }

    private static func draw(_ photo: CGImage, slot: SlotSnapshot, context ctx: CGContext) {
        ctx.saveGState()
        let center = CGPoint(x: slot.x + slot.width / 2, y: slot.y + slot.height / 2)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: slot.rotation * .pi / 180)
        let slotRect = CGRect(x: -slot.width / 2, y: -slot.height / 2, width: slot.width, height: slot.height)
        ctx.clip(to: slotRect)
        let photoW = CGFloat(photo.width), photoH = CGFloat(photo.height)
        let fit = max(slot.width / photoW, slot.height / photoH)
        let drawRect = CGRect(x: -photoW * fit / 2, y: -photoH * fit / 2, width: photoW * fit, height: photoH * fit)
        drawTopLeft(photo, in: drawRect, context: ctx)
        ctx.restoreGState()
    }

    private static func drawTopLeft(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    enum ExportError: Error {
        case noClips
    }
}
