import Foundation

/// SRT ↔ WebVTT, plus plain text for reading or searching what was said.
enum Subtitles {
    struct Cue {
        var start: Int // milliseconds
        var end: Int
        var text: [String]
    }

    static func convert(_ src: URL, _ dst: URL, _ ext: String) throws {
        let cues = try parse(read(src))
        guard !cues.isEmpty else { throw ConvertError("No subtitles found in the file") }
        let out: String
        switch ext {
        case "srt": out = srt(cues)
        case "vtt": out = vtt(cues)
        case "txt": out = plainText(cues)
        default: throw ConvertError("\(ext.uppercased()) isn’t supported")
        }
        try out.write(to: dst, atomically: true, encoding: .utf8)
    }

    /// Old SRT files are often not UTF-8; fall back to what Foundation detects, then the usual Windows code pages.
    private static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var text = String(data: data, encoding: .utf8)
        if text == nil {
            var detected: String.Encoding = .utf8
            text = try? String(contentsOf: url, usedEncoding: &detected)
        }
        if text == nil { text = String(data: data, encoding: .windowsCP1254) ?? String(data: data, encoding: .windowsCP1252) }
        guard var result = text else { throw ConvertError("Couldn’t read the file") }
        if result.hasPrefix("\u{FEFF}") { result.removeFirst() }
        return result
    }

    /// Both formats are blocks separated by blank lines with an "a --> b" timing line; anything else
    /// (WEBVTT header, NOTE, STYLE, REGION) has no timing line and is skipped.
    static func parse(_ text: String) -> [Cue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [Cue] = []
        var block: [String] = []
        for line in lines + [""] {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(line)
                continue
            }
            defer { block = [] }
            guard let timing = block.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = block[timing].components(separatedBy: "-->")
            // VTT may put cue settings after the end time ("00:05.000 align:start").
            let endField = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let start = milliseconds(parts[0]), let end = milliseconds(endField) else { continue }
            cues.append(Cue(start: start, end: end, text: Array(block[(timing + 1)...])))
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456" or VTT's short "02:03.456".
    private static func milliseconds(_ field: String) -> Int? {
        let parts = field.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!) else { return nil }
        var total = seconds
        for (i, part) in parts.dropLast().reversed().enumerated() {
            guard let value = Double(part) else { return nil }
            total += value * (i == 0 ? 60 : 3600)
        }
        return Int((total * 1000).rounded())
    }

    private static func timestamp(_ ms: Int, separator: String) -> String {
        String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60) + separator + String(format: "%03d", ms % 1000)
    }

    private static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, cue in
            let text = cue.text.map { decodeEntities(stripTags($0, keeping: ["b", "i", "u"])) }
            return "\(i + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
                + text.joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    private static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            // SRT's <font> tags mean nothing in VTT; a bare "-->" in the text would end the cue early.
            let text = cue.text.map { stripTags($0, keeping: ["b", "i", "u"]).replacingOccurrences(of: "-->", with: "->") }
            return "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n" + text.joined(separator: "\n") + "\n"
        }.joined(separator: "\n")
    }

    /// One line per cue. Auto-generated captions repeat the previous line as they roll, so repeats are dropped.
    private static func plainText(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues {
            for line in cue.text {
                let clean = decodeEntities(stripTags(line, keeping: [])).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty && clean != lines.last { lines.append(clean) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes markup such as <v Speaker>, <c.yellow>, <font color=…> and inline <00:01.000> times.
    private static func stripTags(_ line: String, keeping kept: Set<String>) -> String {
        var out = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            out += rest[..<open]
            let tag = rest[rest.index(after: open)..<close].lowercased()
            let name = tag.drop { $0 == "/" }.prefix { $0.isLetter }
            if kept.contains(String(name)) { out += "<\(tag.hasPrefix("/") ? "/" : "")\(name)>" }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// VTT escapes these; SRT and plain text don't.
    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
