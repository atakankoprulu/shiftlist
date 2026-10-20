import AppKit
import ApplicationServices
import ServiceManagement

/// Runs file work off the main thread and reports through a notification when done.
final class JobRunner {
    static let shared = JobRunner()
    var onChange: ((Int) -> Void)?
    private(set) var active = 0 {
        didSet { onChange?(active) }
    }

    func start(files: [URL], label: String, sizes: Bool, work: @escaping () -> JobResult) {
        active += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.active -= 1
                Notifier.shared.report(result, files: files, label: label, sizes: sizes)
            }
        }
    }

    /// Applies `operation` to each file separately.
    func run(files: [URL], label: String, sizes: Bool, operation: @escaping (URL) throws -> URL) {
        start(files: files, label: label, sizes: sizes) {
            var result = JobResult()
            for file in files {
                do { result.outputs.append(try operation(file)) } catch { result.failures.append((file, error.localizedDescription)) }
            }
            return result
        }
    }

    func run(files: [URL], label: String, sizes: Bool, single: @escaping () throws -> URL) {
        run(files: Array(files.prefix(1)), label: label, sizes: sizes) { _ in try single() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var jobsItem: NSMenuItem!
    private var enabledItem: NSMenuItem!
    private var pagesItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!

    private var palette: PaletteController?
    private let shiftTap = ShiftTapDetector()
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no windows; don't let macOS quietly quit it when idle.
        ProcessInfo.processInfo.disableAutomaticTermination("Shiftlist menü çubuğunda çalışır")
        UserDefaults.standard.register(defaults: ["enabled": true, "usePages": true])
        setupStatusItem()
        Notifier.shared.setup()
        JobRunner.shared.onChange = { [weak self] _ in self?.updateStatusButton() }

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.palette?.close()
        }

        shiftTap.onTap = { [weak self] in self?.shiftTapped() }
        // Listening to the keyboard needs Privacy › Accessibility; keep trying until the user allows it.
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        log.notice("launch, accessibility trusted: \(trusted)")
        if !shiftTap.start() {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard let self, self.shiftTap.start() else { return }
                timer.invalidate()
                Notifier.shared.post(title: "Shiftlist hazır", body: "Finder'da bir dosya seç ve Shift'e bir kez bas.", reveal: [])
            }
        }

        // Ask for Finder access right away instead of on first use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = FinderSelection.current()
        }
    }

    // MARK: - Trigger

    private func shiftTapped() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        log.notice("shift tapped, frontmost: \(front, privacy: .public), palette open: \(self.palette != nil)")
        guard UserDefaults.standard.bool(forKey: "enabled"), palette == nil, front == "com.apple.finder" else { return }
        showPaletteForFinderSelection(at: NSEvent.mouseLocation)
    }

    private func showPaletteForFinderSelection(at point: NSPoint) {
        let files = FinderSelection.current()
        log.notice("finder selection: \(files.count) files, error: \(FinderSelection.lastErrorCode ?? 0)")
        if FinderSelection.lastErrorCode == FinderSelection.notPermitted {
            Notifier.shared.post(title: "Finder izni gerekli",
                                 body: "Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon'da Shiftlist için Finder'ı aç.",
                                 reveal: [])
            return
        }
        showPalette(files: files, at: point)
    }

    func showPalette(files: [URL], at point: NSPoint) {
        guard palette == nil else { return }
        guard !files.isEmpty else { return }

        // Open on the first tab that has something to offer; unknown file types still get Actions.
        let mode = PaletteMode.allCases.first { !Menus.items(for: files, mode: $0).isEmpty } ?? .actions
        let controller = PaletteController(files: files, at: point, mode: mode)
        controller.onPick = { [weak self] item in self?.perform(item, on: files) }
        controller.onClose = { [weak self] in self?.palette = nil }
        palette = controller
        controller.show()
    }

    private func perform(_ item: PaletteItem, on files: [URL]) {
        switch item.action {
        case .convert(let target):
            let usePages = UserDefaults.standard.bool(forKey: "usePages")
            JobRunner.shared.start(files: files, label: target.label, sizes: false) {
                ConversionJob(usePages: usePages).run(files: files, target: target)
            }
        case .each(let label, let sizes, let operation):
            JobRunner.shared.run(files: files, label: label, sizes: sizes, operation: operation)
        case .ui(let run):
            run(files)
        case nil:
            break
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "Shiftlist", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for hint in ["Finder'da dosya seç, Shift'e bir kez bas", "⇧ Dönüştür  ·  ⌃ Araçlar  ·  ⌘ İşlemler"] {
            let item = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        jobsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        jobsItem.isEnabled = false
        menu.addItem(jobsItem)
        menu.addItem(withTitle: "Seçili Dosyalar İçin Aç", action: #selector(openForSelection), keyEquivalent: "").target = self
        menu.addItem(.separator())

        enabledItem = menu.addItem(withTitle: "Shift ile Aç", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        pagesItem = menu.addItem(withTitle: "Word → PDF için Pages Kullan", action: #selector(togglePages), keyEquivalent: "")
        pagesItem.target = self
        loginItem = menu.addItem(withTitle: "Girişte Başlat", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        accessibilityItem = menu.addItem(withTitle: "Erişilebilirlik İzni Ver…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(withTitle: "Otomasyon İzinleri…", action: #selector(openAutomationSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        updateStatusButton()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let active = JobRunner.shared.active
        jobsItem.title = active == 0 ? "Sürmekte olan iş yok" : "\(active) iş sürüyor…"
        enabledItem.state = UserDefaults.standard.bool(forKey: "enabled") ? .on : .off
        pagesItem.state = UserDefaults.standard.bool(forKey: "usePages") ? .on : .off
        pagesItem.isHidden = !Tools.pagesInstalled
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.isHidden = shiftTap.isRunning
    }

    private func updateStatusButton() {
        let active = JobRunner.shared.active
        statusItem?.button?.title = active > 0 ? " \(active)" : ""
    }

    @objc private func openForSelection() {
        let point = NSEvent.mouseLocation
        // Let the menu finish closing before the palette takes keyboard focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showPaletteForFinderSelection(at: point)
        }
    }

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "enabled"), forKey: "enabled")
    }

    @objc private func togglePages() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "usePages"), forKey: "usePages")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Notifier.shared.post(title: "Girişte başlatma ayarlanamadı", body: error.localizedDescription, reveal: [])
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// A small list glyph, drawn as a template so it follows the menu bar's color.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2.3, y: 2.8, width: 13.4, height: 12.4), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.5
            frame.stroke()
            // The highlighted middle row, like the palette's hovered item.
            NSBezierPath(roundedRect: NSRect(x: 4.6, y: 7.7, width: 8.8, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
            for y in [5.4, 12.6] {
                NSBezierPath(roundedRect: NSRect(x: 5.4, y: y - 0.65, width: 7.2, height: 1.3), xRadius: 0.65, yRadius: 0.65).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
