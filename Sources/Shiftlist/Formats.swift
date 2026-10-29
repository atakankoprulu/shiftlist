import AppKit

/// Source file families. Each family knows which formats it can be turned into.
enum Kind {
    case image, video, audio, document, markdown, ebook, pdf, pages, archive, subtitle

    static func of(_ url: URL) -> Kind? {
        switch fileFormat(url) {
        case "jpg", "png", "heic", "tiff", "gif", "bmp", "webp", "avif", "ico", "icns", "psd", "tga":
            return .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts":
            return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff", "wma", "caf":
            return .audio
        case "txt", "rtf", "rtfd", "doc", "docx", "odt", "html", "webarchive":
            return .document
        case "md":
            return .markdown
        case "epub":
            return .ebook
        case "pdf":
            return .pdf
        case "pages":
            return .pages
        case "zip", "tar", "tgz", "tbz", "txz", "gz", "bz2", "xz", "rar", "7z":
            return .archive
        case "srt", "vtt":
            return .subtitle
        default:
            return nil
        }
    }
}

/// Collapses spelling variants so "photo.jpeg" and "photo.jpg" count as the same format.
func normalizedExt(_ ext: String) -> String {
    let e = ext.lowercased()
    switch e {
    case "jpeg", "jpe": return "jpg"
    case "tif": return "tiff"
    case "heif": return "heic"
    case "htm": return "html"
    case "aif": return "aiff"
    case "markdown": return "md"
    case "webvtt": return "vtt"
    case "text": return "txt"
    default: return e
    }
}

/// Like `normalizedExt`, but also recognises double extensions such as ".tar.gz".
func fileFormat(_ url: URL) -> String {
    let name = url.lastPathComponent.lowercased()
    if name.hasSuffix(".tar.gz") { return "tgz" }
    if name.hasSuffix(".tar.bz2") { return "tbz" }
    if name.hasSuffix(".tar.xz") { return "txz" }
    return normalizedExt(url.pathExtension)
}

/// File name without its format extension: "proje.tar.gz" → "proje".
func baseName(_ url: URL) -> String {
    let base = url.deletingPathExtension().lastPathComponent
    return ["tgz", "tbz", "txz"].contains(fileFormat(url)) ? (base as NSString).deletingPathExtension : base
}

struct Target: Hashable, Identifiable {
    static let mergeID = "merge"

    /// Output format, or `mergeID` for "combine everything into one PDF".
    let id: String

    var isMerge: Bool { id == Target.mergeID }
    var ext: String {
        switch id {
        case Target.mergeID: return "pdf"
        case "tgz": return "tar.gz"
        default: return id
        }
    }
    var label: String {
        switch id {
        case Target.mergeID: return String(localized: "Merge")
        case "tgz": return "GZIP"
        default: return id.uppercased()
        }
    }
}

enum Tools {
    static let ffmpeg = find("ffmpeg")
    static let ffprobe = find("ffprobe")
    static let pandoc = find("pandoc")
    static let pagesBundleID = "com.apple.iWork.Pages"

    static var pagesInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: pagesBundleID) != nil
    }

    /// Prefers the copy bundled inside the app (an arm64 build against macOS 26, so only used there), then
    /// Homebrew's usual prefixes, since GUI apps don't inherit the shell PATH.
    private static func find(_ name: String) -> String? {
        #if arch(arm64)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
           let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        #endif
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

enum Catalog {
    static func outputs(for kind: Kind) -> [String] {
        switch kind {
        case .image:
            return ["jpg", "png", "heic", "pdf", "avif", "tiff", "gif", "bmp"]
        case .video:
            return Tools.ffmpeg == nil ? [] : ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav"]
        case .audio:
            return Tools.ffmpeg == nil ? [] : ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]
        case .document:
            return ["pdf", "docx", "doc", "rtf", "odt", "html", "txt"] + (Tools.pandoc == nil ? [] : ["md", "epub"])
        case .markdown:
            return Tools.pandoc == nil ? [] : ["pdf", "html", "docx", "odt", "rtf", "epub", "txt"]
        case .ebook:
            return Tools.pandoc == nil ? [] : ["pdf", "docx", "html", "md", "txt"]
        case .pdf:
            return ["png", "jpg", "txt"]
        case .pages:
            return Tools.pagesInstalled ? ["pdf", "docx", "txt", "epub"] : []
        case .archive:
            return ["zip", "tar", "tgz"]
        case .subtitle:
            return ["srt", "vtt", "txt"]
        }
    }

    /// Formats every selected file can be converted to. Mixed selections get the overlap,
    /// e.g. images + Word files only offer PDF.
    static func targets(for files: [URL]) -> [Target] {
        var kinds: [Kind] = []
        for f in files {
            guard let k = Kind.of(f) else { return [] }
            if !kinds.contains(k) { kinds.append(k) }
        }
        guard let first = kinds.first else { return [] }

        var ids = outputs(for: first)
        for k in kinds.dropFirst() {
            let other = outputs(for: k)
            ids = ids.filter(other.contains)
        }

        let sourceFormats = Set(files.map(fileFormat))
        if sourceFormats.count == 1 { ids.removeAll { sourceFormats.contains($0) } }

        var targets = ids.map(Target.init(id:))
        if files.count > 1 && kinds.allSatisfy({ $0 == .image || $0 == .pdf }) {
            targets.insert(Target(id: Target.mergeID), at: 0)
        }
        return targets
    }
}
