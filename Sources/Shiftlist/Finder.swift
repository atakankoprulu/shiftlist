import AppKit

enum FinderSelection {
    /// errAEEventNotPermitted: the user hasn't allowed Shiftlist to control Finder.
    static let notPermitted = -1743

    private static let script = NSAppleScript(source: """
    tell application "Finder"
        set sel to selection as alias list
        set out to ""
        repeat with a in sel
            set out to out & (POSIX path of (a as alias)) & linefeed
        end repeat
        return out
    end tell
    """)

    private(set) static var lastErrorCode: Int?

    /// Files currently selected in Finder. Plain folders are dropped; bundles such as .rtfd stay.
    static func current() -> [URL] {
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        lastErrorCode = error?[NSAppleScript.errorNumber] as? Int
        guard let text = result?.stringValue else { return [] }

        return text.split(separator: "\n").compactMap { line in
            let url = URL(fileURLWithPath: String(line))
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true { return nil }
            return url
        }
    }
}
