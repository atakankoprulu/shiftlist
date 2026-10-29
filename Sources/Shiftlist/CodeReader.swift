import AppKit
import ImageIO
import PDFKit
import Vision

/// Finds QR codes and barcodes in images and PDF pages and copies what they say.
enum CodeReader {
    static func read(_ files: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [String] = []
            for file in files {
                for text in (try? payloads(in: file)) ?? [] where !found.contains(text) { found.append(text) }
            }
            DispatchQueue.main.async { report(found) }
        }
    }

    private static func report(_ found: [String]) {
        guard !found.isEmpty else {
            Notifier.shared.post(title: String(localized: "No code found"),
                                 body: String(localized: "No QR code or barcode was found in the selection."), reveal: [])
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string)
        let title = found.count == 1 ? String(localized: "Code copied") : String(localized: "\(found.count) codes copied")
        // Links are only copied, never opened: a code can point anywhere.
        Notifier.shared.post(title: title, body: found.joined(separator: "\n"), reveal: [])
    }

    static func payloads(in file: URL) throws -> [String] {
        if Kind.of(file) == .pdf {
            guard let doc = PDFDocument(url: file), !doc.isLocked else { throw ConvertError("Couldn’t open the PDF") }
            return (0..<doc.pageCount).flatMap { i in doc.page(at: i).flatMap(render).map(detect) ?? [] }
        }
        return detect(try FileOps.loadImage(file).1)
    }

    private static func detect(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Small codes on a page need a sharp rendering; 200 dpi is plenty without huge bitmaps.
    private static func render(_ page: PDFPage) -> CGImage? {
        guard let cgPage = page.pageRef else { return nil }
        let box = cgPage.getBoxRect(.mediaBox)
        let scale = min(200.0 / 72, 4000 / max(box.width, box.height, 1))
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(cgPage)
        return ctx.makeImage()
    }
}
