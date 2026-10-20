import AppKit
import CoreImage
import SwiftUI

enum EditTool: String, CaseIterable, Identifiable {
    case adjust = "Ayarla", crop = "Kırp", annotate = "Çiz", redact = "Karart"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .crop: return "crop"
        case .annotate: return "pencil.tip"
        case .redact: return "eye.slash"
        }
    }
}

/// All geometry is stored normalized (0…1, top-left origin) so it maps onto both the on-screen
/// preview and the full-resolution image at save time.
struct Stroke {
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat // fraction of image width
}

struct Redaction {
    var rect: CGRect
    var pixelate: Bool
}

final class ImageEditorModel: ObservableObject {
    let url: URL
    let full: CGImage
    let preview: CGImage

    @Published var tool: EditTool
    @Published var brightness = 0.0
    @Published var contrast = 1.0
    @Published var saturation = 1.0
    @Published var warmth = 0.0
    @Published var crop: CGRect?
    @Published var strokes: [Stroke] = []
    @Published var redactions: [Redaction] = []
    @Published var penColor = NSColor.systemRed
    @Published var penWidth: CGFloat = 0.006
    @Published var pixelate = false
    @Published var shownImage: NSImage

    private enum Change { case stroke, redaction, crop(CGRect?) }
    private var history: [Change] = []
    private let context = CIContext()

    init?(url: URL, tool: EditTool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ConversionJob.orientedImage(source, index: ConversionJob.bestIndex(source)) else { return nil }
        self.url = url
        self.tool = tool
        full = image
        preview = max(image.width, image.height) > 1600 ? ((try? FileOps.resized(image, maxSide: 1600)) ?? image) : image
        shownImage = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
    }

    var aspect: CGFloat { CGFloat(full.width) / CGFloat(full.height) }
    var canUndo: Bool { !history.isEmpty }

    func refreshAdjustments() {
        let image = adjusted(preview)
        shownImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func addStroke(_ stroke: Stroke) { strokes.append(stroke); history.append(.stroke) }
    func addRedaction(_ r: Redaction) { redactions.append(r); history.append(.redaction) }
    func setCrop(_ rect: CGRect?) { history.append(.crop(crop)); crop = rect }

    func undo() {
        guard let last = history.popLast() else { return }
        switch last {
        case .stroke: strokes.removeLast()
        case .redaction: redactions.removeLast()
        case .crop(let previous): crop = previous
        }
    }

    private func adjusted(_ image: CGImage) -> CGImage {
        var ci = CIImage(cgImage: image)
        if brightness != 0 || contrast != 1 || saturation != 1 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
            ])
        }
        if warmth != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - warmth * 2500, y: 0),
            ])
        }
        return context.createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
    }

    /// Adjustments → redactions → drawing → crop, at full resolution.
    func render() throws -> CGImage {
        let base = adjusted(full)
        let w = CGFloat(base.width), h = CGFloat(base.height)
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConvertError("Görsel işlenemedi")
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        func pixelRect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        }

        if redactions.contains(where: \.pixelate),
           let pixelated = context.createCGImage(CIImage(cgImage: base).clampedToExtent()
               .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(w, h) / 45, kCIInputCenterKey: CIVector(x: 0, y: 0)]),
               from: CGRect(x: 0, y: 0, width: w, height: h)) {
            for r in redactions where r.pixelate {
                ctx.saveGState()
                ctx.clip(to: pixelRect(r.rect))
                ctx.draw(pixelated, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()
            }
        }
        ctx.setFillColor(.black)
        for r in redactions where !r.pixelate { ctx.fill(pixelRect(r.rect)) }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where stroke.points.count > 0 {
            ctx.setStrokeColor(stroke.color.cgColor)
            ctx.setLineWidth(stroke.width * w)
            let pts = stroke.points.map { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }
            ctx.move(to: pts[0])
            pts.count == 1 ? ctx.addLine(to: pts[0]) : pts.dropFirst().forEach { ctx.addLine(to: $0) }
            ctx.strokePath()
        }

        guard var out = ctx.makeImage() else { throw ConvertError("Görsel işlenemedi") }
        if let crop, crop.width > 0.01, crop.height > 0.01 {
            let rect = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral
            out = out.cropping(to: rect) ?? out
        }
        return out
    }

    func save() throws -> URL {
        let image = try render()
        let format = fileFormat(url)
        let ext = ["jpg", "png", "heic", "tiff", "avif", "bmp"].contains(format) ? format : "png"
        let dst = FileOps.output(url, "düzenlendi", ext: ext)
        try FileOps.writeImage(image, to: dst, ext: ext, quality: 0.92,
                               metadataFrom: CGImageSourceCreateWithURL(url as CFURL, nil))
        return dst
    }
}

struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel
    let onDone: (URL?) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @State private var currentStroke: [CGPoint] = []

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            options
                .frame(height: 54)
                .padding(.horizontal, 16)
        }
        .onChange(of: model.brightness) { _ in model.refreshAdjustments() }
        .onChange(of: model.contrast) { _ in model.refreshAdjustments() }
        .onChange(of: model.saturation) { _ in model.refreshAdjustments() }
        .onChange(of: model.warmth) { _ in model.refreshAdjustments() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.tool) {
                ForEach(EditTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            Spacer()
            Button { model.undo() } label: { Label("Geri Al", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button("Vazgeç") { onDone(nil) }
                .keyboardShortcut(.cancelAction)
            Button("Kaydet") {
                do { onDone(try model.save()) } catch {
                    Notifier.shared.post(title: "Kaydedilemedi", body: error.localizedDescription, reveal: [])
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var options: some View {
        switch model.tool {
        case .adjust:
            HStack(spacing: 18) {
                slider("Parlaklık", $model.brightness, -0.4...0.4)
                slider("Kontrast", $model.contrast, 0.6...1.6)
                slider("Doygunluk", $model.saturation, 0...2)
                slider("Sıcaklık", $model.warmth, -1...1)
                Button("Sıfırla") {
                    model.brightness = 0; model.contrast = 1; model.saturation = 1; model.warmth = 0
                }
            }
        case .crop:
            HStack {
                Text("Kırpmak istediğin alanı sürükleyerek seç.").foregroundStyle(.secondary)
                Spacer()
                Button("Kırpmayı Kaldır") { model.setCrop(nil) }.disabled(model.crop == nil)
            }
        case .annotate:
            HStack(spacing: 10) {
                ForEach(palette, id: \.self) { color in
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(model.penColor == color ? 0.9 : 0.2), lineWidth: model.penColor == color ? 2.5 : 1))
                        .onTapGesture { model.penColor = color }
                }
                Divider().frame(height: 24)
                slider("Kalınlık", Binding(get: { Double(model.penWidth) }, set: { model.penWidth = CGFloat($0) }), 0.002...0.03)
            }
        case .redact:
            HStack {
                Picker("", selection: $model.pixelate) {
                    Text("Siyah kutu").tag(false)
                    Text("Pikselleştir").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Text("Gizlemek istediğin alanı sürükle.").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range).controlSize(.small)
        }
        .frame(minWidth: 110)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fit = fitSize(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: model.shownImage)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                overlay(size: fit)
            }
            .frame(width: fit.width, height: fit.height)
            .contentShape(Rectangle())
            .gesture(drag(size: fit))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func fitSize(in size: CGSize) -> CGSize {
        let w = min(size.width, size.height * model.aspect)
        return CGSize(width: w, height: w / model.aspect)
    }

    private func overlay(size: CGSize) -> some View {
        Canvas { ctx, _ in
            func rect(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
            }
            for r in model.redactions {
                ctx.fill(Path(rect(r.rect)), with: r.pixelate ? .color(.gray.opacity(0.85)) : .color(.black))
                if r.pixelate {
                    ctx.stroke(Path(rect(r.rect)), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            var strokes = model.strokes
            if !currentStroke.isEmpty { strokes.append(Stroke(points: currentStroke, color: model.penColor, width: model.penWidth)) }
            for s in strokes {
                var p = Path()
                let pts = s.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                p.addLines(pts.count == 1 ? [pts[0], pts[0]] : pts)
                ctx.stroke(p, with: .color(Color(nsColor: s.color)),
                           style: StrokeStyle(lineWidth: s.width * size.width, lineCap: .round, lineJoin: .round))
            }
            let live = liveRect
            if model.tool == .redact, let live {
                ctx.fill(Path(rect(live)), with: .color(.black.opacity(0.6)))
            }
            if let crop = model.tool == .crop ? (live ?? model.crop) : model.crop {
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRect(rect(crop))
                ctx.fill(outside, with: .color(.black.opacity(model.tool == .crop ? 0.55 : 0.75)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(rect(crop)), with: .color(.white), lineWidth: 1.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var liveRect: CGRect? {
        guard let a = dragStart, let b = dragNow else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func drag(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.tool != .adjust else { return }
                let p = CGPoint(x: min(max(value.location.x / size.width, 0), 1), y: min(max(value.location.y / size.height, 0), 1))
                if model.tool == .annotate {
                    currentStroke.append(p)
                } else {
                    if dragStart == nil {
                        dragStart = CGPoint(x: min(max(value.startLocation.x / size.width, 0), 1),
                                            y: min(max(value.startLocation.y / size.height, 0), 1))
                    }
                    dragNow = p
                }
            }
            .onEnded { _ in
                switch model.tool {
                case .annotate:
                    if !currentStroke.isEmpty { model.addStroke(Stroke(points: currentStroke, color: model.penColor, width: model.penWidth)) }
                    currentStroke = []
                case .redact:
                    if let r = liveRect, r.width > 0.005, r.height > 0.005 { model.addRedaction(Redaction(rect: r, pixelate: model.pixelate)) }
                case .crop:
                    if let r = liveRect, r.width > 0.02, r.height > 0.02 { model.setCrop(r) }
                case .adjust:
                    break
                }
                dragStart = nil
                dragNow = nil
            }
    }
}

enum ImageEditor {
    private static var windows: [NSWindow] = []

    static func show(_ url: URL, tool: EditTool) {
        guard let model = ImageEditorModel(url: url, tool: tool) else {
            Notifier.shared.post(title: "Açılamadı", body: "\(url.lastPathComponent) okunamadı.", reveal: [])
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) — Shiftlist"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: ImageEditorView(model: model) { [weak window] saved in
            window?.close()
            if let saved {
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            }
        })
        open(window)
    }

    /// Shared by every Shiftlist window: activate, center, and keep a reference until it closes.
    static func open(_ window: NSWindow) {
        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            (note.object as? NSWindow).map { closed in windows.removeAll { $0 === closed } }
        }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
