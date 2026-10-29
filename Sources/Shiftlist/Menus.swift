import AppKit

enum PaletteMode: Int, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return String(localized: "Convert")
        case .tools: return String(localized: "Tools")
        case .actions: return String(localized: "Actions")
        }
    }

    var emptyMessage: String {
        switch self {
        case .convert: return String(localized: "No conversions for this file")
        case .tools: return String(localized: "No tools for this file")
        case .actions: return String(localized: "No actions for this file")
        }
    }

    var keySymbol: String {
        switch self {
        case .convert: return "shift"
        case .tools: return "control"
        case .actions: return "command"
        }
    }
}

enum PaletteAction {
    /// Format conversion through `ConversionJob`.
    case convert(Target)
    /// Background work applied to each selected file; `sizes` adds before/after sizes to the notification.
    case each(label: String, sizes: Bool, (URL) throws -> URL)
    /// Background work that turns the whole selection into one file (collage, joined video).
    case combine(label: String, ([URL]) throws -> URL)
    /// Runs immediately on the main thread (windows, pasteboard, sharing).
    case ui(([URL]) -> Void)
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var symbol: String? = nil
    var children: [PaletteItem] = []
    var action: PaletteAction? = nil

    /// Format names are shown bold; tool names regular with an icon.
    var isFormat: Bool {
        if case .convert = action { return symbol == nil }
        return false
    }
}

enum Menus {
    static func items(for files: [URL], mode: PaletteMode) -> [PaletteItem] {
        switch mode {
        case .convert: return convertItems(files)
        case .tools: return toolItems(files)
        case .actions: return actionItems(files)
        }
    }

    // MARK: - Convert

    private static func convertItems(_ files: [URL]) -> [PaletteItem] {
        Catalog.targets(for: files).map { target in
            PaletteItem(id: "convert-\(target.id)", title: target.label,
                     symbol: target.isMerge ? "doc.on.doc" : nil, action: .convert(target))
        }
    }

    // MARK: - Tools

    private static func toolItems(_ files: [URL]) -> [PaletteItem] {
        var kinds: [Kind] = []
        for f in files {
            guard let k = Kind.of(f) else { return [] }
            if !kinds.contains(k) { kinds.append(k) }
        }
        guard let kind = kinds.first else { return [] }
        let single = files.count == 1
        let playable = single && ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aac", "caf"].contains(fileFormat(files[0]))
        let hasFFmpeg = Tools.ffmpeg != nil

        // Mixed selections only get what works on every kind.
        if kinds.count > 1 {
            let metadataKinds: [Kind] = [.image, .video, .audio, .pdf]
            return kinds.allSatisfy(metadataKinds.contains) && (hasFFmpeg || !kinds.contains(where: { $0 == .video || $0 == .audio }))
                ? [metadata] : []
        }

        var items: [PaletteItem] = []
        switch kind {
        case .image:
            items.append(levels(String(localized: "Compress"), "arrow.down.right.and.arrow.up.left") { try FileOps.compressImage($0, $1) })
            items.append(metadata)
            if single {
                items.append(editor(String(localized: "Edit"), "slider.horizontal.3", .adjust, files[0]))
                items.append(editor(String(localized: "Annotate"), "pencil.tip", .annotate, files[0]))
            }
            items.append(PaletteItem(id: "bg", title: String(localized: "Background"), symbol: "photo.on.rectangle.angled", children: [
                (String(localized: "White"), 0), (String(localized: "Black"), 1), (String(localized: "Sunset"), 2), (String(localized: "Ocean"), 3),
            ].map { name, style in
                PaletteItem(id: "bg-\(style)", title: name, action: .each(label: String(localized: "Background"), sizes: false) {
                    try FileOps.addBackground($0, style: style)
                })
            }))
            if single {
                items.append(editor(String(localized: "Crop"), "crop", .crop, files[0]))
                items.append(editor(String(localized: "Redact"), "eye.slash", .redact, files[0]))
            } else {
                items.append(PaletteItem(id: "collage", title: String(localized: "Collage"), symbol: "rectangle.3.group",
                                      action: .combine(label: String(localized: "Collage")) { try FileOps.collage($0) }))
            }
            items.append(readCodes)

        case .video where hasFFmpeg:
            items.append(levels(String(localized: "Compress"), "arrow.down.right.and.arrow.up.left") { try FileOps.compressVideo($0, $1) })
            items.append(metadata)
            items.append(PaletteItem(id: "mute", title: String(localized: "Mute"), symbol: "speaker.slash",
                                  action: .each(label: String(localized: "Muted"), sizes: false) { try FileOps.mute($0) }))
            if playable {
                items.append(PaletteItem(id: "trim", title: String(localized: "Trim"), symbol: "scissors", action: .ui { MediaWindow.show($0[0], mode: .trim) }))
            }
            items.append(PaletteItem(id: "vcrop", title: String(localized: "Crop"), symbol: "crop", children: [
                (String(localized: "Square"), 1, 1), (String(localized: "Portrait 9:16"), 9, 16), (String(localized: "Landscape 16:9"), 16, 9), ("4:5", 4, 5),
            ].map { name, w, h in
                PaletteItem(id: "vcrop-\(w)x\(h)", title: name, action: .each(label: name, sizes: false) {
                    try FileOps.cropVideo($0, w: w, h: h)
                })
            }))
            items.append(PaletteItem(id: "speed", title: String(localized: "Speed"), symbol: "gauge.with.dots.needle.67percent", children: [
                0.5, 1.5, 2, 4,
            ].map { factor in
                let name = factor.formatted(.number.precision(.fractionLength(0...1))) + "×"
                return PaletteItem(id: "speed-\(factor)", title: name, action: .each(label: String(localized: "Speed \(name)"), sizes: false) {
                    try FileOps.changeSpeed($0, factor: factor)
                })
            }))
            if playable {
                items.append(PaletteItem(id: "snapshot", title: String(localized: "Grab Frame"), symbol: "camera", action: .ui { MediaWindow.show($0[0], mode: .snapshot) }))
            }
            items.append(PaletteItem(id: "split", title: String(localized: "Split"), symbol: "square.split.2x1", children: [2, 3, 4].map { n in
                PaletteItem(id: "split-\(n)", title: String(localized: "\(n) parts"), action: .each(label: String(localized: "\(n) parts"), sizes: false) {
                    try FileOps.splitVideo($0, parts: n)
                })
            }))
            if !single {
                items.append(PaletteItem(id: "join", title: String(localized: "Join"), symbol: "film.stack",
                                      action: .combine(label: String(localized: "Joined")) { try FileOps.joinVideos($0) }))
            }

        case .audio where hasFFmpeg:
            items.append(levels(String(localized: "Compress"), "arrow.down.right.and.arrow.up.left") { try FileOps.compressAudio($0, $1) })
            items.append(metadata)
            items.append(PaletteItem(id: "normalize", title: String(localized: "Normalize"), symbol: "waveform",
                                  action: .each(label: String(localized: "Normalized"), sizes: false) { try FileOps.normalize($0) }))
            if playable {
                items.append(PaletteItem(id: "trim", title: String(localized: "Trim"), symbol: "scissors", action: .ui { MediaWindow.show($0[0], mode: .trim) }))
            }
            items.append(PaletteItem(id: "channels", title: String(localized: "Channels"), symbol: "speaker.wave.2", children: [
                PaletteItem(id: "mono", title: "Mono", action: .each(label: "Mono", sizes: false) { try FileOps.setChannels($0, 1) }),
                PaletteItem(id: "stereo", title: "Stereo", action: .each(label: "Stereo", sizes: false) { try FileOps.setChannels($0, 2) }),
            ]))
            items.append(PaletteItem(id: "waveform", title: String(localized: "Waveform Video"), symbol: "waveform.path",
                                  action: .each(label: String(localized: "Waveform video"), sizes: false) { try FileOps.waveformVideo($0) }))

        case .pdf:
            items.append(PaletteItem(id: "compress", title: String(localized: "Compress"), symbol: "arrow.down.right.and.arrow.up.left",
                                  action: .each(label: String(localized: "Compressed"), sizes: true) { try FileOps.compressPDF($0) }))
            items.append(metadata)
            items.append(PaletteItem(id: "pdfsplit", title: String(localized: "Split"), symbol: "square.split.2x1",
                                  action: .each(label: String(localized: "Split into pages"), sizes: false) { try FileOps.splitPDF($0) }))
            if single {
                items.append(PaletteItem(id: "organize", title: String(localized: "Pages"), symbol: "square.grid.2x2",
                                      action: .ui { PDFOrganizer.show($0[0]) }))
            }
            items.append(readCodes)

        case .archive:
            items.append(PaletteItem(id: "extract", title: String(localized: "Extract"), symbol: "archivebox",
                                  action: .each(label: String(localized: "Archive extracted"), sizes: false) { try FileOps.extract($0) }))

        default:
            break
        }
        return items
    }

    private static var readCodes: PaletteItem {
        PaletteItem(id: "qr", title: String(localized: "Read QR Code"), symbol: "qrcode.viewfinder", action: .ui(CodeReader.read))
    }

    private static var metadata: PaletteItem {
        PaletteItem(id: "metadata", title: String(localized: "Strip Metadata"), symbol: "tag.slash",
                 action: .each(label: String(localized: "Metadata stripped"), sizes: false) { try FileOps.stripMetadata($0) })
    }

    private static func levels(_ title: String, _ symbol: String, _ run: @escaping (URL, FileOps.Level) throws -> URL) -> PaletteItem {
        PaletteItem(id: "compress", title: title, symbol: symbol, children: [
            (String(localized: "Light"), FileOps.Level.light), (String(localized: "Medium"), .medium), (String(localized: "Strong"), .strong),
        ].map { name, level in
            PaletteItem(id: "compress-\(level.rawValue)", title: name, action: .each(label: String(localized: "Compressed"), sizes: true) {
                try run($0, level)
            })
        })
    }

    private static func editor(_ title: String, _ symbol: String, _ tool: EditTool, _ file: URL) -> PaletteItem {
        PaletteItem(id: "edit-\(tool.rawValue)", title: title, symbol: symbol, action: .ui { _ in ImageEditor.show(file, tool: tool) })
    }

    // MARK: - Actions

    private static func actionItems(_ files: [URL]) -> [PaletteItem] {
        [
            PaletteItem(id: "airdrop", title: "AirDrop", symbol: "antenna.radiowaves.left.and.right", action: .ui(FileActions.airDrop)),
            PaletteItem(id: "float", title: String(localized: "Pin"), symbol: "pin", action: .ui(FileActions.float)),
            PaletteItem(id: "copy", title: String(localized: "Copy"), symbol: "doc.on.doc", action: .ui(FileActions.copy)),
            PaletteItem(id: "move", title: String(localized: "Move"), symbol: "arrow.right.doc.on.clipboard", action: .ui(FileActions.move)),
            PaletteItem(id: "path", title: String(localized: "Copy Path"), symbol: "doc.text", action: .ui(FileActions.copyPath)),
            PaletteItem(id: "terminal", title: "Terminal", symbol: "apple.terminal", action: .ui(FileActions.terminal)),
        ]
    }
}
