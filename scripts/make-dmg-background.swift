// Draws the DMG window background (1x and 2x PNG). Usage: swift make-dmg-background.swift <out-dir>
// Icon positions must match scripts/dmg-settings.py: app (170, 215), Applications (470, 215).
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 640, height: 420)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Flip so y grows downward, matching Finder's icon coordinates.
    ctx.cgContext.translateBy(x: 0, y: size.height)
    ctx.cgContext.scaleBy(x: 1, y: -1)

    let full = NSRect(origin: .zero, size: size)
    NSGradient(colors: [NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1),
                        NSColor(red: 0.88, green: 0.92, blue: 1.0, alpha: 1)])!.draw(in: full, angle: 90)

    // Soft glow behind the two icons.
    for x in [170.0, 470.0] {
        let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.85), NSColor(white: 1, alpha: 0)])!
        glow.draw(fromCenter: NSPoint(x: x, y: 215), radius: 0, toCenter: NSPoint(x: x, y: 215), radius: 95, options: [])
    }

    func text(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ])
        // Text draws upside down in the flipped context, so un-flip just for it.
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 0, yBy: y + size * 1.2)
        t.scaleX(by: 1, yBy: -1)
        t.concat()
        attributed.draw(in: NSRect(x: 0, y: 0, width: 640, height: size * 1.6))
        NSGraphicsContext.restoreGraphicsState()
    }

    text("Shiftlist", y: 34, size: 26, weight: .bold, color: NSColor(red: 0.12, green: 0.16, blue: 0.32, alpha: 1))
    text("Drag Shiftlist to Applications to install", y: 72, size: 13.5, weight: .medium,
         color: NSColor(red: 0.30, green: 0.35, blue: 0.50, alpha: 1))
    text("Kurmak için Shiftlist'i Uygulamalar klasörüne sürükle", y: 94, size: 11.5, weight: .regular,
         color: NSColor(red: 0.30, green: 0.35, blue: 0.50, alpha: 0.75))

    // Curved arrow from the app to Applications.
    let blue = NSColor(red: 0.27, green: 0.45, blue: 1.0, alpha: 0.9)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 245, y: 222))
    arrow.curve(to: NSPoint(x: 388, y: 222), controlPoint1: NSPoint(x: 290, y: 188), controlPoint2: NSPoint(x: 345, y: 188))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    blue.setStroke()
    let dash: [CGFloat] = [1, 11]
    arrow.setLineDash(dash, count: 2, phase: 0)
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 400, y: 230))
    head.line(to: NSPoint(x: 377, y: 227))
    head.line(to: NSPoint(x: 392, y: 208))
    head.close()
    blue.setFill()
    head.fill()

    text("If macOS warns on first launch: System Settings › Privacy & Security › “Open Anyway”", y: 290, size: 11,
         weight: .regular, color: NSColor(red: 0.30, green: 0.35, blue: 0.50, alpha: 0.8))
    text("İlk açılışta macOS uyarı verirse: Sistem Ayarları › Gizlilik ve Güvenlik › “Yine de Aç”", y: 307, size: 11,
         weight: .regular, color: NSColor(red: 0.30, green: 0.35, blue: 0.50, alpha: 0.8))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
