import Foundation
import AVFoundation
import CoreGraphics
import AppKit

/// Records the Canon EVF live-view frames into a video clip (for the live photo output).
/// Frames are drawn cover-fit onto a fixed 1280×720 canvas at 30 fps — fixed size because
/// Canon's EVF delivers frames at varying sizes depending on the body.
@MainActor
final class EvfClipRecorder {
    private static let width = 1280
    private static let height = 720
    private static let fps: Int32 = 30

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var frameIndex: Int64 = 0
    private var outputURL: URL?
    private var frameProvider: (() -> CGImage?)?

    func start(to url: URL, frameProvider: @escaping () -> CGImage?) {
        stopTimer()
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.outputURL = url
        self.frameProvider = frameProvider
        frameIndex = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(Self.fps), repeats: true) { _ in
            MainActor.assumeIsolated {
                self.appendFrame()
            }
        }
    }

    func stop() async -> URL? {
        stopTimer()
        guard let writer, let input, frameIndex > 0 else {
            cleanup()
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        let url = outputURL
        cleanup()
        return url
    }

    private func appendFrame() {
        guard let input, let adaptor, input.isReadyForMoreMediaData,
              let frame = frameProvider?(),
              let buffer = Self.pixelBuffer(from: frame) else { return }
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: Self.fps)
        adaptor.append(buffer, withPresentationTime: time)
        frameIndex += 1
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanup() {
        writer = nil
        input = nil
        adaptor = nil
        outputURL = nil
        frameProvider = nil
    }

    /// Draws the frame cover-fit into a fixed 1280×720 buffer.
    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
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

        let imageW = CGFloat(image.width), imageH = CGFloat(image.height)
        let scale = max(CGFloat(width) / imageW, CGFloat(height) / imageH)
        let drawRect = CGRect(
            x: (CGFloat(width) - imageW * scale) / 2,
            y: (CGFloat(height) - imageH * scale) / 2,
            width: imageW * scale,
            height: imageH * scale
        )
        ctx.draw(image, in: drawRect)
        return buffer
    }
}
