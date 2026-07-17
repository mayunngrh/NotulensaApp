import Foundation
import AVFoundation
import CoreGraphics

/// Records Canon EVF live-view frames into a video clip (for the live photo output).
///
/// Frame-tap driven: `CanonCameraService.frameTap` fires on the SDK thread at the
/// camera's real cadence, and each frame is encoded here with its true timestamp — so
/// the clip captures every frame the RP delivers (~30 fps) with correct motion timing,
/// rather than polling at a fixed rate and duplicating/dropping frames.
///
/// All AVAssetWriter work happens on a dedicated serial queue, never the main thread.
final class EvfClipRecorder: @unchecked Sendable {
    private static let width = 1280
    private static let height = 720

    private let queue = DispatchQueue(label: "evf.clip.recorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?
    private var startTime: CFTimeInterval = 0
    private var frameCount = 0
    private var outputURL: URL?

    /// Begins recording. Returns a closure to install as the camera's `frameTap`.
    func start(to url: URL) -> (CGImage) -> Void {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Self.width,
                AVVideoHeightKey: Self.height
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: Self.width,
                    kCVPixelBufferHeightKey as String: Self.height
                ]
            )
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.pixelBufferPool = adaptor.pixelBufferPool
            self.outputURL = url
            self.startTime = CACurrentMediaTime()
            self.frameCount = 0
        }
        return { [weak self] image in
            self?.appendFrame(image)
        }
    }

    /// Called on the SDK thread by the camera's frameTap.
    private func appendFrame(_ image: CGImage) {
        queue.async { [self] in
            guard let input, let adaptor, input.isReadyForMoreMediaData,
                  let buffer = makeBuffer(from: image) else { return }
            let elapsed = CACurrentMediaTime() - startTime
            let time = CMTime(seconds: elapsed, preferredTimescale: 600)
            adaptor.append(buffer, withPresentationTime: time)
            frameCount += 1
        }
    }

    func stop() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let writer, let input, frameCount > 0 else {
                    cleanup()
                    continuation.resume(returning: nil)
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [self] in
                    let url = outputURL
                    cleanup()
                    continuation.resume(returning: url)
                }
            }
        }
    }

    private func cleanup() {
        writer = nil
        input = nil
        adaptor = nil
        pixelBufferPool = nil
        outputURL = nil
    }

    /// Draws the frame cover-fit into a pooled 1280×720 buffer.
    private func makeBuffer(from image: CGImage) -> CVPixelBuffer? {
        var bufferRef: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferRef)
        }
        if bufferRef == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height, kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &bufferRef)
        }
        guard let buffer = bufferRef else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Self.width, height: Self.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        let imageW = CGFloat(image.width), imageH = CGFloat(image.height)
        let scale = max(CGFloat(Self.width) / imageW, CGFloat(Self.height) / imageH)
        ctx.draw(image, in: CGRect(
            x: (CGFloat(Self.width) - imageW * scale) / 2,
            y: (CGFloat(Self.height) - imageH * scale) / 2,
            width: imageW * scale,
            height: imageH * scale
        ))
        return buffer
    }
}
