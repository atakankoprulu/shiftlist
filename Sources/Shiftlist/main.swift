import AppKit
import SwiftUI

// Command-line entry points, handy for testing without clicking around in Finder:
//   Shiftlist --targets <dosyalar…>                      formats offered for the files
//   Shiftlist --convert <format> <dosyalar…>              convert and print the outputs
//   Shiftlist --tool <araç-id> <dosyalar…>                run a Tools item (ids as in Menus.swift, e.g. compress-1, qr)
//   Shiftlist --edit-test <görsel>                        editor pipeline: crop top-left 60%, redact, draw
//   Shiftlist --snapshot <out.png> <mod> <dosyalar…>      render the palette to a PNG (mod: convert, tools, actions)
let args = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared

func fileURLs(_ paths: ArraySlice<String>) -> [URL] {
    paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
}

/// Depth-first search through the Tools tab, including submenus.
func findItem(_ id: String, in items: [PaletteItem]) -> PaletteItem? {
    for item in items {
        if item.id == id { return item }
        if let found = findItem(id, in: item.children) { return found }
    }
    return nil
}

func printResult(_ result: JobResult) -> Never {
    result.outputs.forEach { print("✓ \($0.path)") }
    result.skipped.forEach { print("= \($0.lastPathComponent) skipped") }
    result.failures.forEach { print("✗ \($0.file.lastPathComponent): \($0.message)") }
    exit(result.failures.isEmpty ? 0 : 1)
}

switch args.first {
case "--targets":
    print(Catalog.targets(for: fileURLs(args.dropFirst())).map(\.id).joined(separator: " "))

case "--convert" where args.count >= 3:
    let target = Target(id: args[1])
    let files = fileURLs(args.dropFirst(2))
    app.setActivationPolicy(.prohibited)
    // Conversions run off the main thread and hop back for AppKit work, so the run loop must be spinning.
    DispatchQueue.global().async {
        printResult(ConversionJob(usePages: ProcessInfo.processInfo.environment["SHIFTLIST_NO_PAGES"] == nil)
            .run(files: files, target: target))
    }
    app.run()

case "--tool" where args.count >= 3:
    let files = fileURLs(args.dropFirst(2))
    let item = findItem(args[1], in: Menus.items(for: files, mode: .tools))
    if args[1] == "qr" {
        for file in files { print("\(file.lastPathComponent): \(((try? CodeReader.payloads(in: file)) ?? []).joined(separator: " | "))") }
        exit(0)
    }
    app.setActivationPolicy(.prohibited)
    switch item?.action {
    case .each(_, _, let operation):
        DispatchQueue.global().async {
            var result = JobResult()
            for file in files {
                do { result.outputs.append(try operation(file)) } catch { result.failures.append((file, error.localizedDescription)) }
            }
            printResult(result)
        }
    case .combine(_, let operation):
        DispatchQueue.global().async {
            var result = JobResult()
            do { result.outputs.append(try operation(files)) } catch { result.failures.append((files[0], error.localizedDescription)) }
            printResult(result)
        }
    default:
        print("Tool not found: \(args[1])")
        exit(2)
    }
    app.run()

case "--edit-test" where args.count >= 2:
    guard let model = ImageEditorModel(url: URL(fileURLWithPath: args[1]), tool: .crop) else { exit(2) }
    model.brightness = 0.1
    model.addRedaction(Redaction(rect: CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.1), pixelate: false))
    model.addRedaction(Redaction(rect: CGRect(x: 0.3, y: 0.05, width: 0.2, height: 0.2), pixelate: true))
    model.addStroke(Stroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.5, y: 0.3)], color: .systemRed, width: 0.02))
    model.setCrop(CGRect(x: 0, y: 0, width: 0.6, height: 0.6))
    do { print("✓ \(try model.save().path)") } catch { print("✗ \(error.localizedDescription)"); exit(1) }

case "--snapshot" where args.count >= 4:
    // Renders the palette offscreen. Live glass can't be captured, so this uses the flat fallback style.
    paletteUsesFlatStyle = true
    let out = URL(fileURLWithPath: args[1])
    let mode = ["convert": PaletteMode.convert, "tools": .tools, "actions": .actions][args[2]] ?? .convert
    let files = fileURLs(args.dropFirst(3))
    let layout = PaletteLayout(files: files)
    let model = PaletteModel()
    model.mode = mode
    model.items = Menus.items(for: files, mode: mode)
    model.appeared = true
    model.hovered = ProcessInfo.processInfo.environment["SHIFTLIST_HOVER"].flatMap(Int.init)
    let view = PaletteView(model: model, layout: layout, files: files)
        .background(LinearGradient(colors: [Color(red: 0.62, green: 0.74, blue: 0.86), Color(red: 0.86, green: 0.9, blue: 0.94)],
                                   startPoint: .top, endPoint: .bottom))
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
        }
    }

default:
    // Two copies (e.g. ~/Applications and /Applications) would both answer Shift and stack two palettes.
    let me = ProcessInfo.processInfo.processIdentifier
    if let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
