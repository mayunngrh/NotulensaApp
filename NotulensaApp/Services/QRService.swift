import Foundation
import AppKit
import CoreImage.CIFilterBuiltins

/// Mock QR sharing. Later: upload the result to Google Drive and encode the share link.
enum QRService {
    /// Placeholder URL until Google Drive upload is implemented.
    static func shareURL(for resultRelativePath: String) -> URL {
        URL(string: "https://photobooth.example.com/mock/\(resultRelativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "photo")")!
    }

    static func qrImage(for url: URL, size: CGFloat = 300) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
