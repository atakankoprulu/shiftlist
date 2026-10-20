import AppKit
import AVKit

/// Trim uses AVKit's own trimming bar; Snapshot saves the frame on screen as PNG.
enum MediaWindow {
    enum Mode { case trim, snapshot }

    static func show(_ url: URL, mode: Mode) {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true

        let isAudio = Kind.of(url) == .audio
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: isAudio ? 200 : 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) — \(mode == .trim ? String(localized: "Trim") : String(localized: "Grab Frame"))"
        window.isReleasedWhenClosed = false

        switch mode {
        case .trim:
            window.contentView = playerView
            ImageEditor.open(window)
            Task { @MainActor in
                // The trimming UI needs the item loaded.
                while player.currentItem?.status != .readyToPlay {
                    if player.currentItem?.status == .failed { window.close(); return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard playerView.canBeginTrimming else { window.close(); return }
                let result = await playerView.beginTrimming()
                let item = player.currentItem
                window.close()
                guard result == .okButton, let item else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime.seconds : 0
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : item.duration.seconds
                guard end > start else { return }
                JobRunner.shared.run(files: [url], label: String(localized: "Trimmed"), sizes: false) {
                    try FileOps.trim(url, start: start, end: end)
                }
            }

        case .snapshot:
            let button = NSButton(title: String(localized: "Save This Frame"), target: nil, action: nil)
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            let saver = SnapshotSaver(url: url, player: player)
            button.target = saver
            button.action = #selector(SnapshotSaver.save)
            objc_setAssociatedObject(window, &SnapshotSaver.key, saver, .OBJC_ASSOCIATION_RETAIN)

            let bar = NSStackView(views: [button])
            bar.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            let stack = NSStackView(views: [playerView, bar])
            stack.orientation = .vertical
            stack.spacing = 0
            window.contentView = stack
            ImageEditor.open(window)
        }
    }
}

private final class SnapshotSaver: NSObject {
    static var key = 0
    let url: URL
    let player: AVPlayer

    init(url: URL, player: AVPlayer) {
        self.url = url
        self.player = player
    }

    @objc func save() {
        player.pause()
        let time = player.currentTime()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let url = self.url
        generator.generateCGImageAsynchronously(for: time) { image, _, error in
            DispatchQueue.main.async {
                guard let image else {
                    Notifier.shared.post(title: String(localized: "Couldn’t grab the frame"), body: error?.localizedDescription ?? "", reveal: [])
                    return
                }
                let seconds = Int(time.seconds)
                let dst = FileOps.output(url, String(format: String(localized: "frame %02d.%02d"), seconds / 60, seconds % 60), ext: "png")
                do {
                    try FileOps.writeImage(image, to: dst, ext: "png", quality: 1, metadataFrom: nil)
                    Notifier.shared.post(title: String(localized: "Frame saved"), body: dst.lastPathComponent, reveal: [dst])
                } catch {
                    Notifier.shared.post(title: String(localized: "Couldn’t save the frame"), body: error.localizedDescription, reveal: [])
                }
            }
        }
    }
}
