import AppKit
import Quartz

/// The Actions tab. These run on the main thread right after the palette closes.
enum FileActions {
    static func airDrop(_ files: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard service.canPerform(withItems: files) else {
            Notifier.shared.post(title: String(localized: "AirDrop isn’t available"), body: String(localized: "Are Wi-Fi and Bluetooth on?"), reveal: [])
            return
        }
        service.perform(withItems: files)
    }

    static func float(_ files: [URL]) {
        for file in files.prefix(4) { FloatWindow.show(file) }
    }

    static func copy(_ files: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(files as [NSURL])
        Notifier.shared.post(title: String(localized: "Copied"), body: files.count == 1
            ? String(localized: "\(files[0].lastPathComponent) — paste in Finder with ⌘V.")
            : String(localized: "\(files.count) files — paste in Finder with ⌘V."), reveal: [])
    }

    static func copyPath(_ files: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
        Notifier.shared.post(title: String(localized: "Path copied"),
                             body: files.count == 1 ? files[0].path : String(localized: "Paths of \(files.count) files"), reveal: [])
    }

    static func move(_ files: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Move Here")
        panel.message = files.count == 1 ? String(localized: "Where should \(files[0].lastPathComponent) go?")
                                          : String(localized: "Where should \(files.count) files go?")
        panel.directoryURL = files[0].deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var moved: [URL] = []
        for file in files where file.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
            let ext = file.pathExtension
            let dst = uniqueURL(in: dir, base: file.deletingPathExtension().lastPathComponent, ext: ext.isEmpty ? nil : ext)
            do {
                try FileManager.default.moveItem(at: file, to: dst)
                moved.append(dst)
            } catch {
                Notifier.shared.post(title: String(localized: "Couldn’t move"), body: "\(file.lastPathComponent): \(error.localizedDescription)", reveal: [])
            }
        }
        if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
    }

    static func terminal(_ files: [URL]) {
        let dir = files[0].deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// An always-on-top Quick Look window, for keeping a reference image or PDF in view while working.
enum FloatWindow {
    private static var windows: [NSWindow] = []

    static func show(_ url: URL) {
        var size = NSSize(width: 480, height: 360)
        if let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 {
            let scale = min(520 / image.size.width, 520 / image.size.height, 1)
            size = NSSize(width: max(image.size.width * scale, 200), height: max(image.size.height * scale, 150))
        }
        let mouse = NSEvent.mouseLocation
        let panel = NSPanel(contentRect: NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = url.lastPathComponent
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        guard let preview = QLPreviewView(frame: NSRect(origin: .zero, size: size), style: .normal) else { return }
        preview.previewItem = url as NSURL
        preview.autostarts = true
        panel.contentView = preview
        panel.orderFrontRegardless()

        windows.append(panel)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { note in
            (note.object as? NSWindow).map { closed in windows.removeAll { $0 === closed } }
            preview.close()
        }
    }
}
