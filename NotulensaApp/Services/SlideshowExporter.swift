import Foundation
import AVFoundation
import CoreGraphics

/// MP4 slideshow of the captured photos — same content and timing as the GIF, but
/// far smaller and playable everywhere (WhatsApp, Instagram, iOS Photos, …).
enum SlideshowExporter {
    /// `photos[order]` = captured JPEG per shot. Loops the sequence `loops` times.
    static func export(photos: [Int: Data], width: Int, frameSeconds: Double, loops: Int, eventID: String) async throws -> String {
        let frames = photos.sorted { $0.key < $1.key }.compactMap { Compositor.cgImage(from: $0.value) }
        guard let first = frames.first else { throw ExportError.noFrames }

        // Even dimensions required by H.264.
        let outW = width - (width % 2)
        let rawH = Int(Double(outW) * Double(first.height) / Double(first.width))
        let outH = rawH - (rawH % 2)

        let fileName = "slideshow-\(Int(Date.now.timeIntervalSince1970)).mp4"
        let dir = MediaStore.directory(.sessions).appendingPathComponent(eventID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let frameDuration = CMTimeValue(frameSeconds * 600)
        var buffers: [CVPixelBuffer] = []
        for frame in frames {
            if let buffer = pixelBuffer(from: frame, width: outW, height: outH) {
                buffers.append(buffer)
            }
        }
        guard !buffers.isEmpty else { throw ExportError.noFrames }

        var index: CMTimeValue = 0
        for _ in 0..<max(1, loops) {
            for buffer in buffers {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: index * frameDuration, timescale: timescale))
                index += 1
            }
        }
        // Hold the last frame briefly so the video doesn't cut on the final photo.
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        adaptor.append(buffers[buffers.count - 1], withPresentationTime: CMTime(value: index * frameDuration, timescale: timescale))

        input.markAsFinished()
        await writer.finishWriting()
        return "\(MediaStore.Folder.sessions.rawValue)/\(eventID)/\(fileName)"
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var bufferRef: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &bufferRef)
        guard let buffer = bufferRef else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        // Cover-fit (crop) so every photo fills the frame.
        let imageW = CGFloat(image.width), imageH = CGFloat(image.height)
        let scale = max(CGFloat(width) / imageW, CGFloat(height) / imageH)
        ctx.draw(image, in: CGRect(
            x: (CGFloat(width) - imageW * scale) / 2,
            y: (CGFloat(height) - imageH * scale) / 2,
            width: imageW * scale,
            height: imageH * scale
        ))
        return buffer
    }

    enum ExportError: Error {
        case noFrames
    }
}
