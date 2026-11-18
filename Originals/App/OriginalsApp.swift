import AppKit
import Photos
import SwiftUI


struct OriginalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = PhotoLibrary()
    @State private var exporter = ExportManager.shared
    @State private var icloud = ICloudWebSession.shared

    var body: some Scene {
        Window("Originals", id: "main") {
            ContentView()
                .environment(library)
                .environment(exporter)
                .environment(icloud)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Export Selected Originals…") {
                    ExportPanel.exportSelection(library: library, exporter: exporter)
                }
                .keyboardShortcut("e")
                .disabled(library.selection.isEmpty)

                Button("Export Smaller Versions…") {
                    ExportPanel.exportSelection(library: library, exporter: exporter, variant: .smaller)
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(library.selection.isEmpty)

                if let last = ExportPanel.lastFolder {
                    Button("Export to “\(last.lastPathComponent)”") {
                        exporter.export(library.selectedAssets, to: last)
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(library.selection.isEmpty)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(exporter)
                .environment(icloud)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ExportManager.shared.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Exports are still running"
        alert.informativeText = "Quitting cancels the downloads that haven't finished. Files already exported stay where they are."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

@MainActor
enum ExportPanel {
    static var lastFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: DefaultsKey.lastExportFolder) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func chooseFolder(count: Int, smaller: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = smaller
            ? "Choose a folder for smaller versions of \(count) item\(count == 1 ? "" : "s")"
            : "Choose a folder for \(count) original\(count == 1 ? "" : "s")"
        panel.directoryURL = lastFolder
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: DefaultsKey.lastExportFolder)
        return url
    }

    static func export(_ assets: [PHAsset], exporter: ExportManager, variant: ExportVariant = .original) {
        guard !assets.isEmpty,
              let folder = chooseFolder(count: assets.count, smaller: variant == .smaller) else { return }
        exporter.export(assets, to: folder, variant: variant)
    }

    static func exportSelection(library: PhotoLibrary, exporter: ExportManager, variant: ExportVariant = .original) {
        export(library.selectedAssets, exporter: exporter, variant: variant)
    }
}
