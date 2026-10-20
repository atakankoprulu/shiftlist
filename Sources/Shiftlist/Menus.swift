import AppKit

enum PaletteMode: Int, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return "Dönüştür"
        case .tools: return "Araçlar"
        case .actions: return "İşlemler"
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
            items.append(levels("Sıkıştır", "arrow.down.right.and.arrow.up.left") { try FileOps.compressImage($0, $1) })
            items.append(metadata)
            if single {
                items.append(editor("Düzenle", "slider.horizontal.3", .adjust, files[0]))
                items.append(editor("Not ekle", "pencil.tip", .annotate, files[0]))
            }
            items.append(PaletteItem(id: "bg", title: "Arka plan", symbol: "photo.on.rectangle.angled", children: [
                ("Beyaz", 0), ("Siyah", 1), ("Gün batımı", 2), ("Okyanus", 3),
            ].map { name, style in
                PaletteItem(id: "bg-\(style)", title: name, action: .each(label: "Arka plan", sizes: false) {
                    try FileOps.addBackground($0, style: style)
                })
            }))
            if single {
                items.append(editor("Kırp", "crop", .crop, files[0]))
                items.append(editor("Karart", "eye.slash", .redact, files[0]))
            }

        case .video where hasFFmpeg:
            items.append(levels("Sıkıştır", "arrow.down.right.and.arrow.up.left") { try FileOps.compressVideo($0, $1) })
            items.append(metadata)
            items.append(PaletteItem(id: "mute", title: "Sessiz", symbol: "speaker.slash",
                                  action: .each(label: "Sessiz", sizes: false) { try FileOps.mute($0) }))
            if playable {
                items.append(PaletteItem(id: "trim", title: "Kes", symbol: "scissors", action: .ui { MediaWindow.show($0[0], mode: .trim) }))
            }
            items.append(PaletteItem(id: "vcrop", title: "Kırp", symbol: "crop", children: [
                ("Kare", 1, 1), ("Dikey 9:16", 9, 16), ("Yatay 16:9", 16, 9), ("4:5", 4, 5),
            ].map { name, w, h in
                PaletteItem(id: "vcrop-\(w)x\(h)", title: name, action: .each(label: name, sizes: false) {
                    try FileOps.cropVideo($0, w: w, h: h)
                })
            }))
            items.append(PaletteItem(id: "speed", title: "Hız", symbol: "gauge.with.dots.needle.67percent", children: [
                ("0,5×", 0.5), ("1,5×", 1.5), ("2×", 2), ("4×", 4),
            ].map { name, factor in
                PaletteItem(id: "speed-\(factor)", title: name, action: .each(label: "Hız \(name)", sizes: false) {
                    try FileOps.changeSpeed($0, factor: factor)
                })
            }))
            if playable {
                items.append(PaletteItem(id: "snapshot", title: "Kare al", symbol: "camera", action: .ui { MediaWindow.show($0[0], mode: .snapshot) }))
            }
            items.append(PaletteItem(id: "split", title: "Böl", symbol: "square.split.2x1", children: [2, 3, 4].map { n in
                PaletteItem(id: "split-\(n)", title: "\(n) parça", action: .each(label: "\(n) parça", sizes: false) {
                    try FileOps.splitVideo($0, parts: n)
                })
            }))

        case .audio where hasFFmpeg:
            items.append(levels("Sıkıştır", "arrow.down.right.and.arrow.up.left") { try FileOps.compressAudio($0, $1) })
            items.append(metadata)
            items.append(PaletteItem(id: "normalize", title: "Normalize", symbol: "waveform",
                                  action: .each(label: "Normalize", sizes: false) { try FileOps.normalize($0) }))
            if playable {
                items.append(PaletteItem(id: "trim", title: "Kes", symbol: "scissors", action: .ui { MediaWindow.show($0[0], mode: .trim) }))
            }
            items.append(PaletteItem(id: "channels", title: "Kanal", symbol: "speaker.wave.2", children: [
                PaletteItem(id: "mono", title: "Mono", action: .each(label: "Mono", sizes: false) { try FileOps.setChannels($0, 1) }),
                PaletteItem(id: "stereo", title: "Stereo", action: .each(label: "Stereo", sizes: false) { try FileOps.setChannels($0, 2) }),
            ]))

        case .pdf:
            items.append(PaletteItem(id: "compress", title: "Sıkıştır", symbol: "arrow.down.right.and.arrow.up.left",
                                  action: .each(label: "Sıkıştırıldı", sizes: true) { try FileOps.compressPDF($0) }))
            items.append(metadata)
            items.append(PaletteItem(id: "pdfsplit", title: "Böl", symbol: "square.split.2x1",
                                  action: .each(label: "Sayfalara bölündü", sizes: false) { try FileOps.splitPDF($0) }))
            if single {
                items.append(PaletteItem(id: "organize", title: "Sayfalar", symbol: "square.grid.2x2",
                                      action: .ui { PDFOrganizer.show($0[0]) }))
            }

        case .archive:
            items.append(PaletteItem(id: "extract", title: "Aç", symbol: "archivebox",
                                  action: .each(label: "Arşiv açıldı", sizes: false) { try FileOps.extract($0) }))

        default:
            break
        }
        return items
    }

    private static var metadata: PaletteItem {
        PaletteItem(id: "metadata", title: "Metadata sil", symbol: "tag.slash",
                 action: .each(label: "Metadata silindi", sizes: false) { try FileOps.stripMetadata($0) })
    }

    private static func levels(_ title: String, _ symbol: String, _ run: @escaping (URL, FileOps.Level) throws -> URL) -> PaletteItem {
        PaletteItem(id: "compress", title: title, symbol: symbol, children: [
            ("Hafif", FileOps.Level.light), ("Orta", .medium), ("Güçlü", .strong),
        ].map { name, level in
            PaletteItem(id: "compress-\(level.rawValue)", title: name, action: .each(label: "Sıkıştırıldı", sizes: true) {
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
            PaletteItem(id: "float", title: "Sabitle", symbol: "pin", action: .ui(FileActions.float)),
            PaletteItem(id: "copy", title: "Kopyala", symbol: "doc.on.doc", action: .ui(FileActions.copy)),
            PaletteItem(id: "move", title: "Taşı", symbol: "arrow.right.doc.on.clipboard", action: .ui(FileActions.move)),
            PaletteItem(id: "path", title: "Yolu kopyala", symbol: "doc.text", action: .ui(FileActions.copyPath)),
            PaletteItem(id: "terminal", title: "Terminal", symbol: "apple.terminal", action: .ui(FileActions.terminal)),
        ]
    }
}
