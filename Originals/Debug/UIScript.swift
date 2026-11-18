#if DEBUG
import AppKit
import Photos

/// Developer check only, started by ORIGINALS_UI_SCRIPT: clicks sidebar rows with real mouse events
/// and logs what the library ends up showing, so sidebar behavior can be checked without UI scripting
/// permissions. Each step waits so a screenshot can be taken between them.
@MainActor
enum UIScript {
    static func run(library: PhotoLibrary) async {
        guard let script = ProcessInfo.processInfo.environment["ORIGINALS_UI_SCRIPT"] else { return }
        let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORIGINALS_UI_LOG"] ?? "/dev/null")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        func log(_ text: String) { handle?.write(Data((text + "\n").utf8)) }

        try? await Task.sleep(for: .seconds(4))
        log("start: source \(String(describing: library.source)) title \(library.sourceTitle) count \(library.count)")
        for title in script.split(separator: ",").map(String.init) {
            // "top" scrolls the grid to its first item.
            if title == "top" {
                if let window = NSApp.windows.first(where: { $0.isVisible }),
                   let grid = find(NSCollectionView.self, in: window.contentView) {
                    grid.scroll(.zero)
                }
                try? await Task.sleep(for: .seconds(1))
                log("scrolled to top")
                continue
            }
            // "preview" opens the preview on the newest item in the current view.
            if title == "preview" {
                NotificationCenter.default.post(name: Self.openPreview, object: max(0, library.count - 1))
                try? await Task.sleep(for: .seconds(6))
                log("preview opened on index \(library.count - 1)")
                continue
            }
            // "=Name" picks a sidebar source directly, for windows in the background (which ignore clicks).
            if title.hasPrefix("=") {
                let name = String(title.dropFirst())
                library.source = library.libraryNodes.first { $0.title == name }?.source
                try? await Task.sleep(for: .seconds(1))
                log("set \(name): title \(library.sourceTitle) count \(library.count)")
                try? await Task.sleep(for: .seconds(4))
                continue
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "" || $0.isMainWindow }),
                  let outline = find(NSOutlineView.self, in: window.contentView) else { log("no sidebar outline view"); return }
            log("outline rows: \(outline.numberOfRows), selected \(outline.selectedRow)")
            guard let row = Int(title) ?? (0..<outline.numberOfRows).first(where: { text(in: outline.view(atColumn: 0, row: $0, makeIfNecessary: true)) .contains(title) }) else {
                log("no row titled \(title)"); continue
            }
            let rect = outline.rect(ofRow: row)
            let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    if type == .leftMouseUp { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
                }
            }
            try? await Task.sleep(for: .seconds(2))
            log("clicked \(title) (row \(row), selected \(outline.selectedRow)): source \(String(describing: library.source)) title \(library.sourceTitle) count \(library.count)")
            try? await Task.sleep(for: .seconds(2))
        }
        log("done")
    }

    static let openPreview = Notification.Name("OriginalsUIScriptOpenPreview")

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    private static func text(in view: NSView?) -> String {
        guard let view else { return "" }
        var parts: [String] = []
        if let field = view as? NSTextField { parts.append(field.stringValue) }
        parts.append(view.accessibilityLabel() ?? "")
        for sub in view.subviews { parts.append(text(in: sub)) }
        return parts.joined(separator: " ")
    }
}
#endif
