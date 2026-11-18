import Photos
import SwiftUI

struct PreviewTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

struct ContentView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ExportManager.self) private var exporter
    @Environment(ICloudWebSession.self) private var icloud
    @State private var showQueue = false
    @State private var preview: PreviewTarget?
    @AppStorage(DefaultsKey.thumbnailSize) private var thumbnailSize = 150.0

    var body: some View {
        Group {
            switch library.authorization {
            case .authorized, .limited: browser
            case .notDetermined: AccessView(denied: false)
            default: AccessView(denied: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refreshAuthorization()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: UIScript.openPreview)) { note in
            if let index = note.object as? Int { preview = PreviewTarget(index: index) }
        }
        #endif
        .task {
            await icloud.refresh()
            // Fast downloads are the point of this app: ask right away when there's no sign-in.
            if icloud.state == .signedOut, ProcessInfo.processInfo.environment["ORIGINALS_UI_SCRIPT"] == nil {
                icloud.isSignInPresented = true
            }
            #if DEBUG
            // Developer check only: open the sign-in sheet at launch to look at it.
            if ProcessInfo.processInfo.environment["ORIGINALS_SHOW_SIGNIN"] != nil { icloud.isSignInPresented = true }
            await UIScript.run(library: library)
            #endif
        }
        .sheet(isPresented: Binding(get: { icloud.isSignInPresented }, set: { icloud.isSignInPresented = $0 })) {
            ICloudSignInSheet()
                .environment(icloud)
                .environment(exporter)
        }
    }

    private var browser: some View {
        @Bindable var library = library
        return NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            PhotoGridView(library: library,
                          version: library.assetsVersion,
                          selection: library.selection,
                          thumbnailSize: thumbnailSize,
                          onOpen: { preview = PreviewTarget(index: $0) })
                .safeAreaInset(edge: .top, spacing: 0) { SignInBanner() }
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
                .navigationTitle(library.sourceTitle)
                .toolbar {
                    ToolbarItem {
                        Picker("Show", selection: $library.mediaFilter) {
                            ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .help("Show all items, only photos, or only videos")
                    }
                    ToolbarItem {
                        Slider(value: $thumbnailSize, in: 70...360)
                            .frame(width: 110)
                            .help("Thumbnail size")
                    }
                    ToolbarItem {
                        Menu {
                            Button("Export Originals…") {
                                ExportPanel.exportSelection(library: library, exporter: exporter)
                            }
                            Button("Export Smaller Versions…") {
                                ExportPanel.exportSelection(library: library, exporter: exporter, variant: .smaller)
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        } primaryAction: {
                            ExportPanel.exportSelection(library: library, exporter: exporter)
                        }
                        .disabled(library.selection.isEmpty)
                        .help("Export originals (⌘E), or smaller versions from the menu (⌥⌘E)")
                    }
                    ToolbarItem {
                        ICloudStatusButton()
                    }
                    ToolbarItem {
                        QueueButton(isShown: $showQueue)
                    }
                }
                .inspector(isPresented: $showQueue) {
                    ExportQueueView()
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 600)
                }
        }
        // Keep sidebar and grid content from showing through under the window buttons when scrolled.
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: $preview) { target in
            PreviewView(startIndex: target.index)
        }
        .onChange(of: exporter.items.count) { old, new in
            if new > old { showQueue = true }
        }
    }
}

private struct QueueButton: View {
    @Environment(ExportManager.self) private var exporter
    @Binding var isShown: Bool

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            if exporter.isBusy {
                let fraction = exporter.stats.fraction
                HStack(spacing: 5) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("\(Int(fraction * 100))%")
                        .monospacedDigit()
                }
            } else {
                Label("Exports", systemImage: "tray.and.arrow.down")
            }
        }
        .help("Show export progress")
    }
}

private struct StatusBar: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        HStack(spacing: 6) {
            Text("\(library.count.formatted()) items")
            if !library.selection.isEmpty {
                Text("·")
                Text("\(library.selection.count.formatted()) selected")
                if let summary = library.selectionSummary {
                    Text("·")
                    Text("\(summary.bytes.byteString) in \(summary.files.formatted()) file\(summary.files == 1 ? "" : "s")")
                    if summary.cloudOnly > 0 {
                        Text("·")
                        Label("\(summary.cloudOnly.formatted()) only in iCloud", systemImage: "icloud")
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct AccessView: View {
    @Environment(PhotoLibrary.self) private var library
    let denied: Bool

    var body: some View {
        ContentUnavailableView {
            Label(denied ? "No Access to Photos" : "Photos Access Needed", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(denied
                 ? "Turn on Originals in System Settings › Privacy & Security › Photos, then come back."
                 : "Originals needs to read your Photos library to show it and export originals.")
        } actions: {
            if denied {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Button("Allow Access…") {
                    Task { await library.requestAccess() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Across the top of the grid while not signed in to iCloud: without it, every original that isn't on
/// this Mac crawls through Photos.
private struct SignInBanner: View {
    @Environment(ICloudWebSession.self) private var icloud

    var body: some View {
        switch icloud.state {
        case .signedOut, .failed:
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.icloud")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign in to iCloud for fast downloads")
                            .fontWeight(.semibold)
                        Text(failureText ?? "Without it, originals that aren't on this Mac download through Photos at about 0.7 MB/s.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if failureText != nil {
                        Button("Try Again") { Task { await icloud.refresh() } }
                    }
                    Button("Sign In…") { icloud.isSignInPresented = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            .background(.orange.opacity(0.1))
            .background(.bar)
        default:
            EmptyView()
        }
    }

    private var failureText: String? {
        if case let .failed(message) = icloud.state { return "Couldn't check your iCloud sign-in: \(message)" }
        return nil
    }
}

/// Shows whether fast iCloud downloads are on, and signs in or out.
private struct ICloudStatusButton: View {
    @Environment(ICloudWebSession.self) private var icloud

    var body: some View {
        Menu {
            switch icloud.state {
            case let .signedIn(account):
                Text("Fast downloads on: signed in as \(account.name)")
                Button("Sign Out of iCloud") { Task { await icloud.signOut() } }
            case .checking, .unknown:
                Text("Checking iCloud sign-in…")
            case let .failed(message):
                Text("iCloud sign-in problem: \(message)")
                Button("Try Again") { Task { await icloud.refresh() } }
                Button("Sign In to iCloud…") { icloud.isSignInPresented = true }
            case .signedOut:
                Text("Fast downloads off: Photos limits iCloud downloads to ~0.7 MB/s")
                Button("Sign In to iCloud…") { icloud.isSignInPresented = true }
            }
        } label: {
            Label("iCloud", systemImage: icloud.account != nil ? "bolt.horizontal.icloud.fill" : "icloud.slash")
        }
        .help(icloud.account != nil ? "Fast iCloud downloads are on" : "Sign in to iCloud for fast downloads")
    }
}
