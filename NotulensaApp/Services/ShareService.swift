import Foundation
import AppKit

enum ShareService {
    /// Opens the AirDrop picker for the given file.
    static func airDrop(fileURL: URL) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: [fileURL])
    }

    /// Prints the image fit to the default paper size.
    static func print(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0

        let paper = printInfo.paperSize
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: paper))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let operation = NSPrintOperation(view: imageView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.run()
    }
}
