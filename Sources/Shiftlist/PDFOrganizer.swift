import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Reorder (drag), rotate and delete PDF pages, then save a new copy.
final class PDFOrganizerModel: ObservableObject {
    struct Page: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        var rotation: Int
        let thumbnail: NSImage

        static func == (a: Page, b: Page) -> Bool { a.id == b.id && a.rotation == b.rotation }
    }

    let url: URL
    let document: PDFDocument
    @Published var pages: [Page]
    @Published var dragging: Page?

    init?(url: URL) {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        self.url = url
        document = doc
        pages = (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            return Page(index: i, rotation: 0, thumbnail: page.thumbnail(of: NSSize(width: 240, height: 320), for: .mediaBox))
        }
    }

    func save() throws -> URL {
        let out = PDFDocument()
        for p in pages {
            guard let page = document.page(at: p.index)?.copy() as? PDFPage else { continue }
            page.rotation = (page.rotation + p.rotation) % 360
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0 else { throw ConvertError("No pages left") }
        let dst = FileOps.output(url, String(localized: "edited"), ext: "pdf")
        guard out.write(to: dst) else { throw ConvertError("Couldn’t write the PDF") }
        return dst
    }
}

struct PDFOrganizerView: View {
    @ObservedObject var model: PDFOrganizerModel
    let onDone: (URL?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Drag to reorder. \(model.pages.count) pages")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { onDone(try model.save()) } catch {
                        Notifier.shared.post(title: String(localized: "Couldn’t save"), body: error.localizedDescription, reveal: [])
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                    ForEach(model.pages) { page in
                        cell(page)
                            .onDrag {
                                model.dragging = page
                                return NSItemProvider(object: page.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: Reorder(target: page, model: model))
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func cell(_ page: PDFOrganizerModel.Page) -> some View {
        let number = (model.pages.firstIndex(of: page) ?? 0) + 1
        return VStack(spacing: 6) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(Double(page.rotation)))
                .frame(height: 170)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .opacity(model.dragging == page ? 0.4 : 1)
            HStack(spacing: 10) {
                Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { rotate(page) } label: { Image(systemName: "rotate.right") }
                    .buttonStyle(.borderless)
                    .help("Rotate")
                Button { withAnimation { model.pages.removeAll { $0.id == page.id } } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
            }
        }
    }

    private func rotate(_ page: PDFOrganizerModel.Page) {
        guard let i = model.pages.firstIndex(where: { $0.id == page.id }) else { return }
        withAnimation { model.pages[i].rotation = (model.pages[i].rotation + 90) % 360 }
    }

    private struct Reorder: DropDelegate {
        let target: PDFOrganizerModel.Page
        let model: PDFOrganizerModel

        func dropEntered(info: DropInfo) {
            guard let dragging = model.dragging, dragging.id != target.id,
                  let from = model.pages.firstIndex(where: { $0.id == dragging.id }),
                  let to = model.pages.firstIndex(where: { $0.id == target.id }) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                model.pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            model.dragging = nil
            return true
        }
    }
}

enum PDFOrganizer {
    static func show(_ url: URL) {
        guard let model = PDFOrganizerModel(url: url) else {
            Notifier.shared.post(title: String(localized: "Couldn’t open"),
                                 body: String(localized: "\(url.lastPathComponent) couldn’t be read or is encrypted."), reveal: [])
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) — \(String(localized: "Pages"))"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PDFOrganizerView(model: model) { [weak window] saved in
            window?.close()
            if let saved { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        })
        ImageEditor.open(window)
    }
}
