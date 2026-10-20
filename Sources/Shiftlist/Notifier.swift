import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `label` is the format ("JPG") or the tool ("Sıkıştırıldı"); `sizes` appends "4,2 MB → 1,1 MB".
    func report(_ result: JobResult, files: [URL], label: String, sizes: Bool = false) {
        if let failure = result.failures.first {
            let title = result.failures.count == 1 ? "Yapılamadı" : "\(result.failures.count) dosyada hata"
            post(title: title, body: "\(failure.file.lastPathComponent): \(failure.message)", reveal: result.outputs)
            return
        }
        guard let first = result.outputs.first else {
            if !result.skipped.isEmpty {
                post(title: "Değişiklik yok", body: "Seçili dosyalar zaten \(label) formatında.", reveal: [])
            }
            return
        }
        var body: String
        if result.outputs.count == 1 && files.count - result.skipped.count == 1 {
            let src = files.first { !result.skipped.contains($0) } ?? files[0]
            body = "\(src.lastPathComponent) → \(first.lastPathComponent)"
        } else if result.outputs.count == 1 {
            body = "\(files.count) dosya → \(first.lastPathComponent)"
        } else {
            body = "\(result.outputs.count) dosya → \(label)"
        }
        if sizes {
            let before = files.map(Self.size).reduce(0, +), after = result.outputs.map(Self.size).reduce(0, +)
            let fmt = ByteCountFormatter()
            body += "\n\(fmt.string(fromByteCount: before)) → \(fmt.string(fromByteCount: after))"
            if after >= before { body += " (daha küçük olmadı)" }
        }
        post(title: result.outputs.count == 1 && !sizes ? "Hazır ✓" : "\(label) ✓", body: body, reveal: result.outputs)
    }

    private static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    func post(title: String, body: String, reveal: [URL]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["paths": reveal.map(\.path)]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the notification shows the new files in Finder.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        if !paths.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
        completionHandler()
    }
}
