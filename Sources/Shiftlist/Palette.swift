import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Geometry shared by the SwiftUI drawing and the AppKit hit testing. Coordinates are top-left origin.
///
/// The panel is sized for the longest list any tab or submenu can show; the card inside grows and
/// shrinks with the current list, and the transparent rest of the panel counts as "outside".
struct PaletteLayout {
    let rows: Int
    let margin: CGFloat = 28
    let inset: CGFloat = 6
    let header: CGFloat = 46
    let tabs: CGFloat = 28
    let row: CGFloat = 28
    let cardWidth: CGFloat = 248
    let corner: CGFloat = 14
    /// Where the cursor sits relative to the card's top-left corner.
    let anchor = CGPoint(x: 14, y: 14)

    init(files: [URL]) {
        func tallest(_ items: [PaletteItem]) -> Int { items.reduce(items.count) { max($0, tallest($1.children)) } }
        rows = max(1, PaletteMode.allCases.map { tallest(Menus.items(for: files, mode: $0)) }.max() ?? 1)
    }

    var size: CGSize { CGSize(width: cardWidth + margin * 2, height: cardHeight(rows: rows) + margin * 2) }
    func cardHeight(rows n: Int) -> CGFloat { inset * 3 + header + tabs + row * CGFloat(n) }
    func card(rows n: Int) -> CGRect { CGRect(x: margin, y: margin, width: cardWidth, height: cardHeight(rows: n)) }

    var headerRect: CGRect { CGRect(x: margin + inset, y: margin + inset, width: cardWidth - inset * 2, height: header) }
    var tabsRect: CGRect { CGRect(x: headerRect.minX, y: headerRect.maxY, width: headerRect.width, height: tabs) }
    var listTop: CGFloat { tabsRect.maxY + inset }

    func index(at p: CGPoint, of n: Int) -> Int? {
        guard p.x >= headerRect.minX, p.x <= headerRect.maxX, p.y >= listTop else { return nil }
        let i = Int((p.y - listTop) / row)
        return i < n ? i : nil
    }

    func mode(at p: CGPoint) -> PaletteMode? {
        guard tabsRect.contains(p) else { return nil }
        let third = tabsRect.width / 3
        return PaletteMode(rawValue: min(2, Int((p.x - tabsRect.minX) / third)))
    }
}

final class PaletteModel: ObservableObject {
    @Published var mode: PaletteMode = .convert
    @Published var stack: [PaletteItem] = []
    @Published var items: [PaletteItem] = []
    @Published var hovered: Int?
    @Published var picked: Int?
    @Published var appeared = false
    @Published var thumbnail: NSImage?

    /// The empty state still takes one row.
    var rowCount: Int { max(1, items.count) }
}

/// `ImageRenderer` can't draw live glass or materials, so snapshots for testing use a flat fill.
var paletteUsesFlatStyle = false

private extension View {
    @ViewBuilder
    func surface<S: Shape>(_ shape: S) -> some View {
        if paletteUsesFlatStyle {
            self.background(shape.fill(Color(white: 0.97)))
        } else if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    let layout: PaletteLayout
    let files: [URL]

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: layout.corner, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: layout.header)
            tabs.frame(height: layout.tabs)
            Divider().padding(.horizontal, 4).frame(height: layout.inset)
            list
        }
        .padding(layout.inset)
        .frame(width: layout.cardWidth, height: layout.cardHeight(rows: model.rowCount), alignment: .top)
        .clipShape(shape)
        .surface(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .scaleEffect(model.appeared ? 1 : 0.96, anchor: .topLeading)
        .opacity(model.appeared ? 1 : 0)
        .padding(layout.margin)
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.appeared)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.rowCount)
        .onAppear { model.appeared = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.thumbnail ?? icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) files"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let parent = model.stack.last {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                        Text(parent.title)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                } else {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private var subtitle: String {
        guard files.count == 1 else { return String(localized: "Multiple files") }
        return (try? files[0].resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? ""
    }

    private var icon: NSImage {
        files.count == 1
            ? NSWorkspace.shared.icon(forFile: files[0].path)
            : NSWorkspace.shared.icon(forFiles: files.map(\.path)) ?? NSWorkspace.shared.icon(forFile: files[0].path)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(PaletteMode.allCases, id: \.rawValue) { mode in
                let active = model.mode == mode
                HStack(spacing: 4) {
                    Image(systemName: mode.keySymbol).font(.system(size: 9, weight: .semibold))
                    Text(mode.title).font(.system(size: 11, weight: active ? .semibold : .regular))
                }
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.14))
                    }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                Text(model.mode.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: layout.row)
            }
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                PaletteRow(item: item, number: i + 1, hot: model.hovered == i, pressed: model.picked == i)
                    .frame(height: layout.row)
            }
        }
        .id("\(model.mode.rawValue)-\(model.stack.count)")
        .transition(.opacity)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let number: Int
    let hot: Bool
    let pressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let symbol = item.symbol ?? (item.isFormat ? "arrow.forward" : nil) {
                    Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .frame(width: 18)
            Text(item.title)
                .font(item.isFormat ? .system(size: 12.5, weight: .semibold, design: .rounded) : .system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !item.children.isEmpty {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).opacity(0.6)
            } else if number <= 9 {
                Text("\(number)").font(.system(size: 11, design: .monospaced)).opacity(0.45)
            }
        }
        .foregroundStyle(hot ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hot ? Color.accentColor : .clear)
        }
        .opacity(pressed ? 0.7 : 1)
    }
}

// MARK: - Window

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns all mouse and keyboard handling so clicks work even though Shiftlist is never the active app.
final class PaletteContainerView: NSView {
    let layout: PaletteLayout
    let model: PaletteModel
    var onPick: ((Int) -> Void)?
    var onMode: ((PaletteMode) -> Void)?
    var onBack: (() -> Void)?
    var onCancel: (() -> Void)?

    init(layout: PaletteLayout, model: PaletteModel) {
        self.layout = layout
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: layout.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hovered = layout.index(at: p, of: model.items.count)
        if model.hovered != hovered { model.hovered = hovered }
    }

    override func mouseExited(with event: NSEvent) {
        model.hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let mode = layout.mode(at: p) {
            onMode?(mode)
        } else if let i = layout.index(at: p, of: model.items.count) {
            onPick?(i)
        } else if layout.headerRect.contains(p) {
            onBack?()
        } else if !layout.card(rows: model.rowCount).contains(p) {
            onCancel?()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            onMode?(.actions)
        } else if flags.contains(.control) || flags.contains(.option) {
            onMode?(.tools)
        } else if flags.contains(.shift) {
            onMode?(.convert)
        }
    }

    override func keyDown(with event: NSEvent) {
        let count = model.items.count
        switch event.keyCode {
        case 53: // esc
            model.stack.isEmpty ? onCancel?() : onBack?()
        case 36, 76: // return, enter
            if let i = model.hovered { onPick?(i) }
        case 48: // tab
            onMode?(PaletteMode(rawValue: (model.mode.rawValue + 1) % 3)!)
        case 123: // left
            onBack?()
        case 124: // right: only opens submenus
            if let i = model.hovered, !model.items[i].children.isEmpty { onPick?(i) }
        case 126 where count > 0: // up
            model.hovered = ((model.hovered ?? 0) - 1 + count) % count
        case 125 where count > 0: // down
            model.hovered = ((model.hovered ?? -1) + 1) % count
        default:
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit >= 1, digit <= min(9, count) {
                onPick?(digit - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

final class PaletteController: NSObject, NSWindowDelegate {
    let files: [URL]
    var onPick: ((PaletteItem) -> Void)?
    var onClose: (() -> Void)?

    private let panel: PalettePanel
    private let model = PaletteModel()
    private var finished = false

    init(files: [URL], at point: NSPoint, mode: PaletteMode = .convert) {
        self.files = files
        let layout = PaletteLayout(files: files)
        let size = layout.size

        // Open like a context menu: the card's top-left corner just under the cursor, whole panel on screen.
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - layout.margin - layout.anchor.x,
                             y: point.y + layout.margin + layout.anchor.y - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }

        panel = PalettePanel(contentRect: NSRect(origin: origin, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let container = PaletteContainerView(layout: layout, model: model)
        let hosting = NSHostingView(rootView: PaletteView(model: model, layout: layout, files: files))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        panel.contentView = container
        super.init()

        panel.delegate = self
        container.onPick = { [weak self] i in self?.pick(i) }
        container.onMode = { [weak self] mode in self?.setMode(mode) }
        container.onBack = { [weak self] in self?.back() }
        container.onCancel = { [weak self] in self?.close() }

        model.mode = mode
        model.items = Menus.items(for: files, mode: mode)
        loadThumbnail()
    }

    func show() {
        log.notice("palette shown: \(self.files.count) files, mode \(self.model.mode.rawValue), \(self.model.items.count) items")
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    func setMode(_ mode: PaletteMode) {
        guard !finished, model.mode != mode || !model.stack.isEmpty else { return }
        model.mode = mode
        model.stack = []
        model.hovered = nil
        model.items = Menus.items(for: files, mode: mode)
    }

    private func back() {
        guard !model.stack.isEmpty else { return }
        model.stack.removeLast()
        model.hovered = nil
        model.items = model.stack.last?.children ?? Menus.items(for: files, mode: model.mode)
    }

    private func pick(_ i: Int) {
        guard !finished, model.picked == nil, model.items.indices.contains(i) else { return }
        let item = model.items[i]
        if !item.children.isEmpty {
            model.stack.append(item)
            model.hovered = nil
            model.items = item.children
            return
        }
        model.picked = i
        let callback = onPick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.close()
            callback?(item)
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        panel.delegate = nil
        let panel = self.panel
        model.appeared = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func loadThumbnail() {
        guard files.count == 1 else { return }
        let request = QLThumbnailGenerator.Request(fileAt: files[0], size: CGSize(width: 68, height: 68),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.model.thumbnail = image }
        }
    }
}
