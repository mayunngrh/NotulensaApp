import Foundation
import AVFoundation
import CoreGraphics

/// Records Canon EVF live-view frames into a video clip (for the live photo output).
///
/// Frame-tap driven with stable frame timing and backpressure handling:
/// - Timestamps based on frame count (not wall clock) for consistent ~33ms intervals
/// - Queues frames even if encoder is busy (up to 60-frame buffer) instead of dropping
/// - Optimized pixel buffer handling to reduce encoder stalls
/// - All work on dedicated serial queue, never main thread
final class EvfClipRecorder: @unchecked Sendable {
    private static let width = 1280
    private static let height = 720
    private static let frameDuration = CMTime(value: 1, timescale: 30)

    private let queue = DispatchQueue(label: "evf.clip.recorder", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameQueue: [(CGImage, CMTime)] = []
    private var frameCount = 0
    private var outputURL: URL?
    private var encodingTask: Task<Void, Never>?

    /// Begins recording. Returns a closure to install as the camera's `frameTap`.
    func start(to url: URL) -> (CGImage) -> Void {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Self.width,
                AVVideoHeightKey: Self.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ] as [String: Any]
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
            self.frameCount = 0
            self.frameQueue = []
            self.startEncodingLoop()
        }
        return { [weak self] image in
            self?.enqueueFrame(image)
        }
    }

    /// Queue frame for encoding (called from SDK thread, doesn't block).
    private func enqueueFrame(_ image: CGImage) {
        queue.async { [weak self] in
            guard let self else { return }
            let time = CMTime(value: Int64(self.frameCount), timescale: 30)
            self.frameQueue.append((image, time))
            self.frameCount += 1
            if self.frameQueue.count > 60 { self.frameQueue.removeFirst() }
        }
    }

    /// Continuously drain the frame queue to the encoder (prevents backpressure stalls).
    private func startEncodingLoop() {
        encodingTask?.cancel()
        encodingTask = Task {
            while !Task.isCancelled {
                queue.async { [weak self] in
                    self?.drainFrameQueue()
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private func drainFrameQueue() {
        guard let input, input.isReadyForMoreMediaData, !frameQueue.isEmpty else { return }
        while let (image, time) = frameQueue.first, input.isReadyForMoreMediaData,
              let buffer = makeBuffer(from: image) {
            adaptor?.append(buffer, withPresentationTime: time)
            frameQueue.removeFirst()
        }
    }

    func stop() async -> URL? {
        encodingTask?.cancel()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                drainFrameQueue()
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
        encodingTask?.cancel()
        encodingTask = nil
        writer = nil
        input = nil
        adaptor = nil
        pixelBufferPool = nil
        outputURL = nil
        frameQueue = []
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
