import AppKit
import ImageIO
import PDFKit

/// The Tools tab: one-shot file operations. Every function writes a new file next to the original
/// and returns it; originals are never modified.
enum FileOps {
    enum Level: Int { case light, medium, strong }

    // MARK: - Images

    static func compressImage(_ src: URL, _ level: Level) throws -> URL {
        let (source, image) = try loadImage(src)
        let format = fileFormat(src)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)

        // JPEG/HEIC shrink through quality; PNG with transparency can only shrink by losing pixels.
        let outExt: String
        switch format {
        case "jpg", "heic": outExt = format
        case "png" where hasAlpha: outExt = "png"
        default: outExt = "jpg"
        }
        let quality = [0.75, 0.6, 0.45][level.rawValue]
        let maxSide: Int? = outExt == "png" ? [2400, 1800, 1200][level.rawValue] : [nil, 3000, 2000][level.rawValue]

        var out = image
        if let maxSide, max(image.width, image.height) > maxSide {
            out = try resized(image, maxSide: maxSide)
        }
        let dst = output(src, String(localized: "compressed"), ext: outExt)
        try writeImage(out, to: dst, ext: outExt, quality: quality, metadataFrom: source)
        return dst
    }

    static func addBackground(_ src: URL, style: Int) throws -> URL {
        let (_, image) = try loadImage(src)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = (max(w, h) * 0.08).rounded()
        let size = CGSize(width: w + pad * 2, height: h + pad * 2)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertError("Couldn’t process the image")
        }
        let stops: [(NSColor, NSColor)] = [
            (.white, NSColor(white: 0.94, alpha: 1)),
            (NSColor(white: 0.16, alpha: 1), NSColor(white: 0.04, alpha: 1)),
            (NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 1), NSColor(red: 0.96, green: 0.30, blue: 0.42, alpha: 1)),
            (NSColor(red: 0.36, green: 0.70, blue: 1.0, alpha: 1), NSColor(red: 0.47, green: 0.33, blue: 0.95, alpha: 1)),
        ]
        let (top, bottom) = stops[min(style, stops.count - 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])

        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let corner = min(w, h) * 0.025
        let rounded = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -pad * 0.15), blur: pad * 0.45, color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.addPath(rounded)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(rounded)
        ctx.clip()
        ctx.draw(image, in: rect)

        guard let result = ctx.makeImage() else { throw ConvertError("Couldn’t process the image") }
        let outExt = ["jpg", "heic"].contains(fileFormat(src)) ? fileFormat(src) : "png"
        let dst = output(src, String(localized: "with background"), ext: outExt)
        try writeImage(outExt == "jpg" ? ConversionJob.flattened(result) : result, to: dst, ext: outExt, quality: 0.92, metadataFrom: nil)
        return dst
    }

    /// Square cells in a near-square grid; each photo fills its cell and is center-cropped.
    static func collage(_ files: [URL]) throws -> URL {
        let images = try files.map { try loadImage($0).1 }
        let cols = Int(Double(images.count).squareRoot().rounded(.up))
        let rows = (images.count + cols - 1) / cols
        let cell = CGFloat(max(600, 2400 / cols)), gap = (cell * 0.02).rounded()
        let size = CGSize(width: CGFloat(cols) * cell + CGFloat(cols + 1) * gap, height: CGFloat(rows) * cell + CGFloat(rows + 1) * gap)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertError("Couldn’t process the image")
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        for (i, image) in images.enumerated() {
            // CGContext's origin is bottom-left; fill rows from the top.
            let x = gap + CGFloat(i % cols) * (cell + gap)
            let y = size.height - CGFloat(i / cols + 1) * (cell + gap)
            let rect = CGRect(x: x, y: y, width: cell, height: cell)
            let scale = max(cell / CGFloat(image.width), cell / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            ctx.restoreGState()
        }
        guard let result = ctx.makeImage() else { throw ConvertError("Couldn’t process the image") }
        let dst = uniqueURL(in: files[0].deletingLastPathComponent(), base: String(localized: "Collage"), ext: "jpg")
        try writeImage(result, to: dst, ext: "jpg", quality: 0.9, metadataFrom: nil)
        return dst
    }

    static func loadImage(_ src: URL) throws -> (CGImageSource, CGImage) {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let image = ConversionJob.orientedImage(source, index: ConversionJob.bestIndex(source)) else {
            throw ConvertError("Couldn’t read the image")
        }
        return (source, image)
    }

    static func resized(_ image: CGImage, maxSide: Int) throws -> CGImage {
        let scale = CGFloat(maxSide) / CGFloat(max(image.width, image.height))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertError("Couldn’t shrink the image")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ConvertError("Couldn’t shrink the image") }
        return out
    }

    static func writeImage(_ image: CGImage, to dst: URL, ext: String, quality: Double, metadataFrom source: CGImageSource?) throws {
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, ConversionJob.imageType(for: ext) as CFString, 1, nil) else {
            throw ConvertError("Can’t write \(ext.uppercased())")
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1]
        if let source, let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = meta[key] { props[key] = value }
            }
        }
        let final = ext == "jpg" ? try ConversionJob.flattened(image) : image
        CGImageDestinationAddImage(dest, final, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn’t save the image") }
    }

    // MARK: - Metadata

    static func stripMetadata(_ src: URL) throws -> URL {
        // Images in formats ImageIO can read but not write (WebP, PSD, ICO…) come out as PNG.
        let ext = Kind.of(src) == .image ? strippedImageExt(src) : src.pathExtension.lowercased()
        let dst = output(src, String(localized: "no metadata"), ext: ext == fileFormat(src) ? src.pathExtension.lowercased() : ext)
        do {
            switch Kind.of(src) {
            case .image: try stripImageMetadata(src, dst)
            case .video, .audio:
                try runFFmpeg(["-i", src.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"], output: dst)
            case .pdf: try stripPDFMetadata(src, dst)
            default: throw ConvertError("Can’t strip metadata from this file")
            }
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
        return dst
    }

    /// Re-encodes pixels only: EXIF, GPS, XMP and camera data are all left behind.
    private static func strippedImageExt(_ src: URL) -> String {
        let ext = fileFormat(src)
        return ["jpg", "png", "heic", "tiff", "gif", "bmp", "avif"].contains(ext) ? ext : "png"
    }

    private static func stripImageMetadata(_ src: URL, _ dst: URL) throws {
        let (source, image) = try loadImage(src)
        let ext = fileFormat(src)
        let outExt = strippedImageExt(src)
        if CGImageSourceGetCount(source) > 1 && ext == "gif" {
            guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, ConversionJob.imageType(for: "gif") as CFString,
                                                             CGImageSourceGetCount(source), nil) else { throw ConvertError("Can’t write GIF") }
            for i in 0..<CGImageSourceGetCount(source) {
                let delay = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary]
                if let frame = CGImageSourceCreateImageAtIndex(source, i, nil) {
                    CGImageDestinationAddImage(dest, frame, delay.map { [kCGImagePropertyGIFDictionary: $0] as CFDictionary })
                }
            }
            guard CGImageDestinationFinalize(dest) else { throw ConvertError("Couldn’t save GIF") }
            return
        }
        // Same format: copy the compressed image data as is and drop the metadata, so nothing is re-encoded.
        if outExt == ext, let type = CGImageSourceGetType(source),
           let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, 1, nil) {
            // Keep only the orientation tag, otherwise portrait photos would come out sideways.
            let metadata = CGImageMetadataCreateMutable()
            if let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                             orientation as CFTypeRef)
            }
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) { return }
            try? FileManager.default.removeItem(at: dst)
        }
        try writeImage(image, to: dst, ext: outExt, quality: 0.9, metadataFrom: nil)
    }

    private static func stripPDFMetadata(_ src: URL, _ dst: URL) throws {
        guard let doc = PDFDocument(url: src) else { throw ConvertError("Couldn’t open the PDF") }
        if doc.isLocked { throw ConvertError("The PDF is encrypted") }
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.copy() as? PDFPage { clean.insert(page, at: clean.pageCount) }
        }
        clean.documentAttributes = [PDFDocumentAttribute.creatorAttribute: "", PDFDocumentAttribute.producerAttribute: ""]
        guard clean.write(to: dst) else { throw ConvertError("Couldn’t write the PDF") }
    }

    // MARK: - Video

    private static func videoExt(_ src: URL) -> String {
        let f = fileFormat(src)
        return ["mp4", "mov", "mkv", "webm", "avi"].contains(f) ? f : "mp4"
    }

    static func compressVideo(_ src: URL, _ level: Level) throws -> URL {
        let crf = ["26", "30", "34"][level.rawValue]
        let side = [nil, 1920, 1280][level.rawValue]
        var filter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        if let side {
            filter = "scale='min(iw,\(side))':'min(ih,\(side))':force_original_aspect_ratio=decrease:force_divisible_by=2"
        }
        let dst = output(src, String(localized: "compressed"), ext: "mp4")
        try runFFmpeg(["-i", src.path, "-vf", filter, "-c:v", "libx264", "-preset", "medium", "-crf", crf, "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", level == .strong ? "96k" : "128k", "-sn", "-dn", "-movflags", "+faststart"], output: dst)
        return dst
    }

    static func mute(_ src: URL) throws -> URL {
        let dst = output(src, String(localized: "muted"), ext: src.pathExtension.lowercased())
        try runFFmpeg(["-i", src.path, "-map", "0:v", "-c", "copy", "-an"], output: dst)
        return dst
    }

    /// Center crop to an aspect ratio such as 9:16.
    static func cropVideo(_ src: URL, w: Int, h: Int) throws -> URL {
        let ext = videoExt(src)
        let filter = "crop='min(iw,ih*\(w)/\(h))':'min(ih,iw*\(h)/\(w))'"
        let dst = output(src, "\(w)x\(h)", ext: ext)
        try runFFmpeg(["-i", src.path] + ConversionJob.mediaArgs(for: ext, videoFilter: filter), output: dst)
        return dst
    }

    static func changeSpeed(_ src: URL, factor: Double) throws -> URL {
        let ext = videoExt(src)
        let label = factor.formatted(.number.precision(.fractionLength(0...1))) + "x"
        let dst = output(src, label, ext: ext)
        let audio = hasAudio(src) ? "atempo=\(factor)" : nil
        try runFFmpeg(["-i", src.path] + ConversionJob.mediaArgs(for: ext, videoFilter: "setpts=PTS/\(factor)", audioFilter: audio), output: dst)
        return dst
    }

    static func splitVideo(_ src: URL, parts: Int) throws -> URL {
        let duration = try mediaDuration(src)
        let folder = uniqueURL(in: src.deletingLastPathComponent(), base: "\(baseName(src)) (\(String(localized: "parts")))", ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let length = duration / Double(parts)
        for i in 0..<parts {
            let part = folder.appendingPathComponent("\(baseName(src))-\(i + 1).\(src.pathExtension.lowercased())")
            try runFFmpeg(["-ss", String(format: "%.3f", Double(i) * length), "-i", src.path, "-t", String(format: "%.3f", length),
                           "-map", "0", "-c", "copy", "-avoid_negative_ts", "make_zero"], output: part)
        }
        return folder
    }

    /// Plays the videos one after another. Everything is fitted (letterboxed) into the first video's frame;
    /// clips without sound get silence so the audio stays in sync.
    static func joinVideos(_ files: [URL]) throws -> URL {
        guard files.count > 1 else { throw ConvertError("Select at least two videos") }
        let (width, height) = try videoSize(files[0])
        var inputs: [String] = [], graph: [String] = [], pairs = ""
        let audio = files.map(hasAudio)
        let withAudio = audio.contains(true)
        var silences: [String] = [], silenceCount = 0
        for (i, file) in files.enumerated() {
            inputs += ["-i", file.path]
            graph.append("[\(i):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,"
                         + "setsar=1,fps=30,format=yuv420p[v\(i)]")
            pairs += "[v\(i)]"
            guard withAudio else { continue }
            if audio[i] {
                graph.append("[\(i):a]aformat=sample_rates=48000:channel_layouts=stereo[a\(i)]")
                pairs += "[a\(i)]"
            } else {
                let duration = try mediaDuration(file)
                silences += ["-f", "lavfi", "-t", String(format: "%.3f", duration), "-i", "anullsrc=r=48000:cl=stereo"]
                pairs += "[\(files.count + silenceCount):a]"
                silenceCount += 1
            }
        }
        graph.append(pairs + "concat=n=\(files.count):v=1:a=\(withAudio ? 1 : 0)[v]" + (withAudio ? "[a]" : ""))
        let dst = output(files[0], String(localized: "joined"), ext: "mp4")
        try runFFmpeg(inputs + silences + ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"] + (withAudio ? ["-map", "[a]"] : [])
                      + ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
                         "-movflags", "+faststart"], output: dst)
        return dst
    }

    /// Display size, i.e. swapped for phone videos stored sideways with a rotation tag. Even, for x264.
    private static func videoSize(_ src: URL) throws -> (Int, Int) {
        guard let ffprobe = Tools.ffprobe else { throw ConvertError("ffprobe not found") }
        let out = try captureTool(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                            "stream=width,height:stream_side_data=rotation:stream_tags=rotate", "-of", "default=nw=1", src.path])
        var values: [String: Int] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Double(parts[1]) { values[String(parts[0])] = Int(value) }
        }
        guard var w = values["width"], var h = values["height"], w > 0, h > 0 else { throw ConvertError("Couldn’t read the video") }
        if abs(values["rotation"] ?? values["TAG:rotate"] ?? 0) % 180 == 90 { swap(&w, &h) }
        return (w / 2 * 2, h / 2 * 2)
    }

    /// Cuts [start, end] out of a video or audio file. Video is re-encoded so the cut lands on the exact frame.
    static func trim(_ src: URL, start: Double, end: Double) throws -> URL {
        let isVideo = Kind.of(src) == .video
        let ext = isVideo ? videoExt(src) : src.pathExtension.lowercased()
        let dst = output(src, String(localized: "trimmed"), ext: ext)
        let codec = isVideo ? try ConversionJob.mediaArgs(for: ext) : ["-c", "copy"]
        try runFFmpeg(["-ss", String(format: "%.3f", start), "-i", src.path, "-t", String(format: "%.3f", end - start)] + codec, output: dst)
        return dst
    }

    // MARK: - Audio

    static func compressAudio(_ src: URL, _ level: Level) throws -> URL {
        let bitrate = ["192k", "128k", "64k"][level.rawValue]
        let aac = ["m4a", "aac"].contains(fileFormat(src))
        let dst = output(src, String(localized: "compressed"), ext: aac ? "m4a" : "mp3")
        try runFFmpeg(["-i", src.path, "-vn", "-c:a", aac ? "aac" : "libmp3lame", "-b:a", bitrate], output: dst)
        return dst
    }

    static func normalize(_ src: URL) throws -> URL {
        // loudnorm measures over a 3 s window and outputs nothing for shorter clips.
        if let duration = try? mediaDuration(src), duration < 3 { throw ConvertError("Normalizing needs at least 3 seconds of audio") }
        return try reencodeAudio(src, suffix: String(localized: "normalized"), filter: "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000")
    }

    static func setChannels(_ src: URL, _ channels: Int) throws -> URL {
        try reencodeAudio(src, suffix: channels == 1 ? "mono" : "stereo", extra: ["-ac", String(channels)])
    }

    /// A video of the moving waveform, for posting audio where only video is accepted.
    static func waveformVideo(_ src: URL) throws -> URL {
        let graph = "[0:a]aformat=channel_layouts=mono,showwaves=s=1280x720:mode=cline:rate=30:colors=0xFFB340[w];"
            + "color=c=0x1C1C1E:s=1280x720:r=30[bg];[bg][w]overlay=shortest=1,format=yuv420p[v]"
        let dst = output(src, String(localized: "waveform"), ext: "mp4")
        try runFFmpeg(["-i", src.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "medium",
                       "-crf", "23", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart"], output: dst)
        return dst
    }

    private static func reencodeAudio(_ src: URL, suffix: String, filter: String? = nil, extra: [String] = []) throws -> URL {
        let format = fileFormat(src)
        let ext = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"].contains(format) ? format : "m4a"
        let dst = output(src, suffix, ext: ext)
        try runFFmpeg(["-i", src.path] + ConversionJob.mediaArgs(for: ext, audioFilter: filter) + extra, output: dst)
        return dst
    }

    private static func hasAudio(_ src: URL) -> Bool {
        guard let ffprobe = Tools.ffprobe else { return true }
        let out = (try? captureTool(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", src.path])) ?? ""
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func mediaDuration(_ src: URL) throws -> Double {
        guard let ffprobe = Tools.ffprobe else { throw ConvertError("ffprobe not found") }
        let out = try captureTool(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", src.path])
        guard let value = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw ConvertError("Couldn’t read the duration")
        }
        return value
    }

    // MARK: - PDF

    static func compressPDF(_ src: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConvertError("Couldn’t open the PDF") }
        if doc.isLocked { throw ConvertError("The PDF is encrypted") }
        let dst = output(src, String(localized: "compressed"), ext: "pdf")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard doc.write(to: dst, withOptions: options) else { throw ConvertError("Couldn’t write the PDF") }
        return dst
    }

    static func splitPDF(_ src: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConvertError("Couldn’t open the PDF") }
        if doc.isLocked { throw ConvertError("The PDF is encrypted") }
        guard doc.pageCount > 1 else { throw ConvertError("The PDF has only one page") }
        let folder = uniqueURL(in: src.deletingLastPathComponent(), base: "\(baseName(src)) (\(String(localized: "pages")))", ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
            single.write(to: folder.appendingPathComponent("\(baseName(src))-\(number).pdf"))
        }
        return folder
    }

    // MARK: - Archives

    static func extract(_ src: URL) throws -> URL {
        let folder = uniqueURL(in: src.deletingLastPathComponent(), base: baseName(src), ext: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try extractArchive(src, into: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("__MACOSX"))
        return folder
    }

    // MARK: - Helpers

    /// "holiday.jpg" + "compressed" → "holiday (compressed).jpg", numbered if taken.
    static func output(_ src: URL, _ suffix: String, ext: String) -> URL {
        uniqueURL(in: src.deletingLastPathComponent(), base: "\(baseName(src)) (\(suffix))", ext: ext)
    }
}

func captureTool(_ path: String, _ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
