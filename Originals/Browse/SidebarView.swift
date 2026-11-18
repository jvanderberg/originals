import SwiftUI

struct SidebarView: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: $library.source) {
            Section("Photos") {
                ForEach(library.libraryNodes) { row($0) }
            }
            if !library.albumNodes.isEmpty {
                Section("Albums") {
                    OutlineGroup(library.albumNodes, children: \.children) { row($0) }
                }
            }
            if !library.sharedNodes.isEmpty {
                Section("Shared Albums") {
                    ForEach(library.sharedNodes) { row($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ node: SidebarNode) -> some View {
        if let source = node.source {
            // A plain tag: SwiftUI matches it against the optional selection itself. Tagging with
            // Optional(source) double-wraps it, and then no row ever matches the selection.
            Label(node.title, systemImage: node.symbol).tag(source)
        } else {
            // Folders only group albums; leaving them untagged makes them unselectable.
            Label(node.title, systemImage: node.symbol)
        }
    }
}
