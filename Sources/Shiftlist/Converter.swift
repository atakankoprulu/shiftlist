import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String.LocalizationValue) { self.message = String(localized: message) }
    init(verbatim message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct JobResult {
    var outputs: [URL] = []
    var failures: [(file: URL, message: String)] = []
    var skipped: [URL] = []
}

/// One batch of conversions. Runs on a background queue; AppKit-only steps hop to the main thread.
final class ConversionJob {
    private let usePages: Bool
    private var pagesTouched = false

    init(usePages: Bool) {
        self.usePages = usePages
    }

    func run(files: [URL], target: Target) -> JobResult {
        var result = JobResult()
        let pagesWasRunning = Self.pagesRunning
        defer {
            if pagesTouched && !pagesWasRunning { Self.quitPages() }
        }

        if target.isMerge {
            do {
                let dst = uniqueURL(in: files[0].deletingLastPathComponent(), base: String(localized: "Merged"), ext: "pdf")
                try mergeToPDF(files, dst)
                result.outputs.append(dst)
            } catch {
                result.failures.append((files[0], error.localizedDescription))
            }
            return result
        }

        for file in files {
            if fileFormat(file) == target.id {
                result.skipped.append(file)
                continue
            }
            do {
                result.outputs.append(try convert(file, to: target.ext))
            } catch {
                result.failures.append((file, error.localizedDescription))
            }
        }
        return result
    }

    // MARK: - Dispatch

    private func convert(_ src: URL, to ext: String) throws -> URL {
        guard let kind = Kind.of(src) else { throw ConvertError("Unsupported file type") }
        if kind == .pdf { return try convertPDF(src, to: ext) }

        let dst = uniqueURL(in: src.deletingLastPathComponent(), base: baseName(src), ext: ext)
        do {
            switch kind {
            case .image: try convertImage(src, dst, ext)
            case .video, .audio: try convertMedia(src, dst, ext)
            case .document: try convertDocument(src, dst, ext)
            case .markdown, .ebook: try convertWithPandoc(src, dst, ext)
            case .pages: try pagesExport(src, dst, ext)
            case .archive: try convertArchive(src, dst, ext)
            case .subtitle: try Subtitles.convert(src, dst, ext)
            case .pdf: break
            }
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
        guard FileManager.default.fileExists(atPath: dst.path) else { throw ConvertError("No output file was created") }
        return dst
    }

    // MARK: - Images

    private func convertImage(_ src: URL, _ dst: URL, _ ext: String) throws {
        if ext == "pdf" { return try mergeToPDF([src], dst) }

        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConvertError("Couldn’t read the image")
        }
        let type = Self.imageType(for: ext)
        let animated = ext == "gif" && CGImageSourceGetCount(source) > 1
        let frames = animated ? CGImageSourceGetCount(source) : 1
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type as CFString, frames, nil) else {
            throw ConvertError("Can’t write \(ext.uppercased())")
        }

        if animated {
            if let props = CGImageSourceCopyProperties(source, nil) { CGImageDestinationSetProperties(dest, props) }
            for i in 0..<frames { CGImageDestinationAddImageFromSource(dest, source, i, nil) }
        } else {
            let index = Self.bestIndex(source)
            guard var image = Self.orientedImage(source, index: index) else { throw ConvertError("Couldn’t read the image") }
            if ext == "jpg" || ext == "bmp" { image = try Self.flattened(image) }

            var props: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyOrientation: 1,
            ]
            if let meta = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                    if let value = meta[key] { props[key] = value }
                }
            }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn’t save \(ext.uppercased())") }
    }

    static func imageType(for ext: String) -> String {
        switch ext {
        case "jpg": return UTType.jpeg.identifier
        case "png": return UTType.png.identifier
        case "heic": return UTType.heic.identifier
        case "avif": return "public.avif"
        case "tiff": return UTType.tiff.identifier
        case "gif": return UTType.gif.identifier
        case "bmp": return UTType.bmp.identifier
        default: return UTType.png.identifier
        }
    }

    /// Icon files hold several sizes; pick the largest. Everything else uses the primary image.
    static func bestIndex(_ source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1, let type = CGImageSourceGetType(source) as String?,
              type == "com.microsoft.ico" || type == "com.apple.icns" else {
            return CGImageSourceGetPrimaryImageIndex(source)
        }
        var best = 0, bestArea = 0
        for i in 0..<count {
            let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let area = (p?[kCGImagePropertyPixelWidth] as? Int ?? 0) * (p?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if area > bestArea { best = i; bestArea = area }
        }
        return best
    }

    /// Decodes at full size with the EXIF rotation baked in, so the output never comes out sideways.
    static func orientedImage(_ source: CGImageSource, index: Int) -> CGImage? {
        let p = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let w = p?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    /// JPEG/BMP have no alpha; put transparent areas on white instead of letting them turn black.
    static func flattened(_ image: CGImage) throws -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvertError("Couldn’t process the image")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw ConvertError("Couldn’t process the image") }
        return out
    }

    /// Images and PDFs, in selection order, into a single PDF.
    private func mergeToPDF(_ files: [URL], _ dst: URL) throws {
        let doc = PDFDocument()
        for file in files {
            if Kind.of(file) == .pdf {
                guard let src = PDFDocument(url: file) else { throw ConvertError("Couldn’t open \(file.lastPathComponent)") }
                if src.isLocked { throw ConvertError("\(file.lastPathComponent) is encrypted") }
                for i in 0..<src.pageCount {
                    if let page = src.page(at: i)?.copy() as? PDFPage { doc.insert(page, at: doc.pageCount) }
                }
            } else {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = Self.orientedImage(source, index: Self.bestIndex(source)) else {
                    throw ConvertError("Couldn’t read \(file.lastPathComponent)")
                }
                let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let dpi = max(meta?[kCGImagePropertyDPIWidth] as? Double ?? 72, 72)
                let size = NSSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
                guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else {
                    throw ConvertError("Couldn’t add \(file.lastPathComponent) to the PDF")
                }
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0, doc.write(to: dst) else { throw ConvertError("Couldn’t write the PDF") }
    }

    // MARK: - PDF

    private func convertPDF(_ src: URL, to ext: String) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConvertError("Couldn’t open the PDF") }
        if doc.isLocked { throw ConvertError("The PDF is encrypted") }
        let dir = src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent

        if ext == "txt" {
            let dst = uniqueURL(in: dir, base: base, ext: "txt")
            let text = doc.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ConvertError("The PDF has no text (it may be a scanned document)")
            }
            try text.write(to: dst, atomically: true, encoding: .utf8)
            return dst
        }

        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let dst = uniqueURL(in: dir, base: base, ext: ext)
            try renderPage(page, to: dst, ext: ext)
            return dst
        }

        // Multi-page PDFs get a folder of numbered page images.
        let folder = uniqueURL(in: dir, base: "\(base) (\(String(localized: "pages")))", ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let number = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
            try renderPage(page, to: folder.appendingPathComponent("\(base)-\(number).\(ext)"), ext: ext)
        }
        return folder
    }

    private func renderPage(_ page: PDFPage, to dst: URL, ext: String) throws {
        guard let cgPage = page.pageRef else { throw ConvertError("Couldn’t read the page") }
        let scale: CGFloat = 2 // 144 dpi
        let box = cgPage.getBoxRect(.mediaBox)
        let rotated = abs(cgPage.rotationAngle) % 180 == 90
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let width = Int(pageSize.width * scale), height = Int(pageSize.height * scale)

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvertError("Couldn’t draw the page")
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(cgPage.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cgPage)

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, Self.imageType(for: ext) as CFString, 1, nil) else {
            throw ConvertError("Couldn’t save the page")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn’t save the page") }
    }

    // MARK: - Video & audio

    private func convertMedia(_ src: URL, _ dst: URL, _ ext: String) throws {
        try runFFmpeg(["-i", src.path] + Self.mediaArgs(for: ext), output: dst)
    }

    /// Encoder settings per output format. `videoFilter` runs before the even-size scale x264 needs;
    /// `audioFilter` is applied to every audio output.
    static func mediaArgs(for ext: String, videoFilter: String? = nil, audioFilter: String? = nil) throws -> [String] {
        func vf(_ tail: String) -> [String] { ["-vf", [videoFilter, tail].compactMap { $0 }.joined(separator: ",")] }
        let af = audioFilter.map { ["-af", $0] } ?? []
        let h264 = vf("scale=trunc(iw/2)*2:trunc(ih/2)*2") + ["-c:v", "libx264", "-preset", "medium", "-crf", "20",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-sn", "-dn"] + af
        switch ext {
        case "mp4", "m4v": return h264 + ["-movflags", "+faststart"]
        case "mov", "mkv": return h264
        case "avi": return vf("null") + ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3", "-sn", "-dn"] + af
        case "webm": return vf("null") + ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good",
                                          "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k", "-sn", "-dn"] + af
        case "gif": return ["-an"] + vf("fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4")
                        + ["-loop", "0"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"] + af
        case "m4a", "aac": return ["-vn", "-c:a", "aac", "-b:a", "256k"] + af
        case "wav": return ["-vn", "-c:a", "pcm_s16le"] + af
        case "flac": return ["-vn", "-c:a", "flac"] + af
        case "ogg", "oga": return ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "6"] + af
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"] + af
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"] + af
        default: throw ConvertError("\(ext.uppercased()) isn’t supported")
        }
    }

    // MARK: - Archives

    private func convertArchive(_ src: URL, _ dst: URL, _ ext: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shiftlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try extractArchive(src, into: tmp)
        try packArchive(contentsOf: tmp, to: dst, ext: ext)
    }

    // MARK: - Documents

    private func convertDocument(_ src: URL, _ dst: URL, _ ext: String) throws {
        let srcExt = normalizedExt(src.pathExtension)
        switch ext {
        case "pdf":
            // Pages keeps Word layout (tables, images, page setup) far better than AppKit's importer.
            if usePages && (srcExt == "docx" || srcExt == "doc") && Tools.pagesInstalled {
                do { return try pagesExport(src, dst, "pdf") } catch { try? FileManager.default.removeItem(at: dst) }
            }
            try attributedToPDF(loadAttributed(src), dst)
        case "md", "epub":
            try convertWithPandoc(src, dst, ext)
        default:
            try runTool("/usr/bin/textutil", ["-convert", ext, src.path, "-output", dst.path])
        }
    }

    private func convertWithPandoc(_ src: URL, _ dst: URL, _ ext: String) throws {
        guard let pandoc = Tools.pandoc else { throw ConvertError("pandoc not found (brew install pandoc)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shiftlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // pandoc can't read .doc/.rtfd/.webarchive; go through HTML first.
        var input = src
        var inputArgs: [String] = []
        switch normalizedExt(src.pathExtension) {
        case "doc", "rtfd", "webarchive":
            input = tmp.appendingPathComponent("girdi.html")
            try runTool("/usr/bin/textutil", ["-convert", "html", src.path, "-output", input.path])
        case "txt":
            inputArgs = ["-f", "markdown"]
        default:
            break
        }

        let base = [input.path] + inputArgs + ["--quiet"]
        switch ext {
        case "pdf":
            let html = tmp.appendingPathComponent("cikti.html")
            try runTool(pandoc, base + ["-s", "--embed-resources", "-V", "mainfont=Helvetica Neue, Helvetica, sans-serif",
                                         "-V", "fontsize=11pt", "-o", html.path])
            try attributedToPDF(loadAttributed(html), dst)
        case "txt":
            try runTool(pandoc, base + ["-t", "plain", "--wrap=none", "-o", dst.path])
        case "md":
            let media = dst.deletingLastPathComponent()
                .appendingPathComponent(dst.deletingPathExtension().lastPathComponent + " (\(String(localized: "images")))")
            try runTool(pandoc, base + ["-t", "gfm", "--wrap=none", "--extract-media=\(media.path)", "-o", dst.path])
        case "html":
            try runTool(pandoc, base + ["-s", "--embed-resources", "-o", dst.path])
        default:
            try runTool(pandoc, base + ["-s", "-o", dst.path])
        }
    }

    private func loadAttributed(_ url: URL) throws -> NSAttributedString {
        try onMain {
            var attrs: NSDictionary?
            let loaded = try NSAttributedString(url: url, options: [:], documentAttributes: &attrs)
            let type = attrs?[NSAttributedString.DocumentAttributeKey.documentType.rawValue] as? String
            guard type == NSAttributedString.DocumentType.plain.rawValue else { return loaded }
            return NSAttributedString(string: loaded.string, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black,
            ])
        }
    }

    /// Lays the text out on A4 pages and prints straight to a PDF file.
    private func attributedToPDF(_ text: NSAttributedString, _ dst: URL) throws {
        let ok: Bool = onMain {
            let paper = NSSize(width: 595.28, height: 841.89)
            let margin: CGFloat = 56
            let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: dst])
            info.jobDisposition = .save
            info.paperSize = paper
            info.topMargin = margin
            info.bottomMargin = margin
            info.leftMargin = margin
            info.rightMargin = margin
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false

            let width = paper.width - 2 * margin
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            view.appearance = NSAppearance(named: .aqua) // never print white-on-white from dark mode
            view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
            view.isVerticallyResizable = true
            view.textStorage?.setAttributedString(text)
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            view.sizeToFit()

            let op = NSPrintOperation(view: view, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            return op.run()
        }
        guard ok else { throw ConvertError("Couldn’t create the PDF") }
    }

    // MARK: - Pages

    private static var pagesRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Tools.pagesBundleID).isEmpty
    }

    private static func quitPages() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Tools.pagesBundleID).forEach { $0.terminate() }
    }

    private func pagesExport(_ src: URL, _ dst: URL, _ ext: String) throws {
        let format: String
        switch ext {
        case "pdf": format = "PDF"
        case "docx": format = "Word"
        case "txt": format = "TXT"
        case "epub": format = "EPUB"
        default: throw ConvertError("Pages can’t export \(ext.uppercased())")
        }
        pagesTouched = true
        let script = """
        on run argv
            set src to POSIX file (item 1 of argv)
            set dst to POSIX file (item 2 of argv)
            set fmt to item 3 of argv
            tell application id "\(Tools.pagesBundleID)"
                with timeout of 90 seconds
                    set d to open src
                    if fmt is "PDF" then
                        export d to dst as PDF
                    else if fmt is "Word" then
                        export d to dst as Microsoft Word
                    else if fmt is "TXT" then
                        export d to dst as unformatted text
                    else
                        export d to dst as EPUB
                    end if
                    close d saving no
                end timeout
            end tell
        end run
        """
        try runTool("/usr/bin/osascript", ["-e", script, src.path, dst.path, format], timeout: 120)
    }
}

// MARK: - Helpers

/// "foto.jpg", then "foto 2.jpg", "foto 3.jpg"… so nothing is ever overwritten. `ext == nil` names a folder.
func uniqueURL(in dir: URL, base: String, ext: String?) -> URL {
    func make(_ name: String) -> URL {
        ext.map { dir.appendingPathComponent(name).appendingPathExtension($0) } ?? dir.appendingPathComponent(name)
    }
    var url = make(base)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = make("\(base) \(n)")
        n += 1
    }
    return url
}

func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
}

func runTool(_ path: String, _ args: [String], timeout: TimeInterval? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    var output = Data()
    let reader = DispatchGroup()
    reader.enter()
    DispatchQueue.global().async {
        output = pipe.fileHandleForReading.readDataToEndOfFile()
        reader.leave()
    }

    try process.run()
    if finished.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .timedOut {
        process.terminate()
        throw ConvertError("Timed out")
    }
    reader.wait()

    guard process.terminationStatus == 0 else {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
        throw lastLine.isEmpty ? ConvertError("\(URL(fileURLWithPath: path).lastPathComponent) failed")
                               : ConvertError(verbatim: String(lastLine.prefix(200)))
    }
}

// MARK: - Shared tool runners

func runFFmpeg(_ args: [String], output: URL) throws {
    guard let ffmpeg = Tools.ffmpeg else { throw ConvertError("ffmpeg not found (brew install ffmpeg)") }
    try runTool(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + args + [output.path])
}

func extractArchive(_ src: URL, into dir: URL) throws {
    if fileFormat(src) == "zip" {
        try runTool("/usr/bin/ditto", ["-x", "-k", src.path, dir.path])
    } else {
        // bsdtar reads tar, gz, bz2, xz, 7z and rar.
        try runTool("/usr/bin/tar", ["-xf", src.path, "-C", dir.path])
    }
}

func packArchive(contentsOf dir: URL, to dst: URL, ext: String) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
    guard !names.isEmpty else { throw ConvertError("The archive is empty") }
    switch ext {
    case "zip":
        if names.count == 1 {
            try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", dir.appendingPathComponent(names[0]).path, dst.path])
        } else {
            try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", dir.path, dst.path])
        }
    case "tar":
        try runTool("/usr/bin/tar", ["--no-mac-metadata", "-cf", dst.path, "-C", dir.path] + names)
    default:
        try runTool("/usr/bin/tar", ["--no-mac-metadata", "-czf", dst.path, "-C", dir.path] + names)
    }
}
