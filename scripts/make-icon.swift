// Draws the app icon and writes an .icns. Usage: swift scripts/make-icon.swift <out.icns>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Rounded square background on Apple's icon grid.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.20, green: 0.27, blue: 0.78, alpha: 1))!.draw(in: bg, angle: -90)

    // A floating white list card with a soft shadow.
    let card = NSBezierPath(roundedRect: NSRect(x: 232, y: 236, width: 560, height: 552), xRadius: 64, yRadius: 64)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 48, color: NSColor(red: 0.05, green: 0.08, blue: 0.3, alpha: 0.45).cgColor)
    NSColor.white.setFill()
    card.fill()
    ctx.restoreGState()
    NSGradient(starting: NSColor.white, ending: NSColor(red: 0.93, green: 0.95, blue: 1.0, alpha: 1))!.draw(in: card, angle: -90)

    // Header: a file thumbnail and its name.
    NSColor(red: 0.80, green: 0.85, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 290, y: 648, width: 84, height: 84), xRadius: 18, yRadius: 18).fill()
    NSColor(red: 0.62, green: 0.66, blue: 0.76, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 400, y: 690, width: 250, height: 26), xRadius: 13, yRadius: 13).fill()
    NSColor(red: 0.80, green: 0.83, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 400, y: 652, width: 160, height: 20), xRadius: 10, yRadius: 10).fill()

    // Rows, the second one highlighted like a hovered item.
    let rowGray = NSColor(red: 0.78, green: 0.81, blue: 0.88, alpha: 1)
    for (i, y) in [540, 450, 360].enumerated() {
        let y = CGFloat(y)
        if i == 1 {
            NSColor(red: 0.27, green: 0.45, blue: 1.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 268, y: y - 6, width: 488, height: 76), xRadius: 22, yRadius: 22).fill()
            NSColor.white.setFill()
        } else {
            rowGray.setFill()
        }
        NSBezierPath(ovalIn: NSRect(x: 300, y: y + 18, width: 26, height: 26)).fill()
        NSBezierPath(roundedRect: NSRect(x: 352, y: y + 20, width: i == 1 ? 250 : 210, height: 22), xRadius: 11, yRadius: 11).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Shiftlist-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
