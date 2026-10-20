import AppKit
import os

let log = Logger(subsystem: "com.atakankoprulu.shiftlist", category: "app")

/// Watches the keyboard system-wide for a lone Shift press-and-release.
///
/// Uses a Core Graphics event tap rather than `NSEvent` global monitors: the tap can be created the
/// moment the user grants Accessibility, whereas NSEvent monitors stay silent until the app restarts.
final class ShiftTapDetector {
    var onTap: (() -> Void)?

    private var tap: CFMachPort?
    private var shiftDownAt: Date?
    private var loggedFirstEvent = false

    var isRunning: Bool { tap != nil }

    /// Returns false while the app isn't allowed to listen yet; call again later.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        // An active tap only needs Accessibility; a listen-only one would also need Input Monitoring.
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<ShiftTapDetector>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: refcon) else {
            log.notice("event tap could not be created")
            return false
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("event tap running")
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if !loggedFirstEvent {
            loggedFirstEvent = true
            log.notice("first event received from tap")
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let flags = event.flags.intersection([.maskShift, .maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn])
            if flags == .maskShift {
                shiftDownAt = Date()
            } else if flags.isEmpty, let downAt = shiftDownAt, Date().timeIntervalSince(downAt) < 0.4 {
                shiftDownAt = nil
                log.notice("shift tap")
                onTap?()
            } else {
                shiftDownAt = nil
            }
        default:
            // Typing a capital letter or Shift-clicking is not a tap.
            shiftDownAt = nil
        }
    }
}
