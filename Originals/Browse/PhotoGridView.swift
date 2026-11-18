import AppKit
import Photos
import SwiftUI

/// Thumbnail grid backed by NSCollectionView: fast with large libraries, and selection works
/// like Finder (click, ⌘-click to toggle, ⇧-click for a range, drag to rubber-band, ⌘A).
struct PhotoGridView: NSViewRepresentable {
    let library: PhotoLibrary
    /// Passed in (rather than read inside the coordinator) so SwiftUI calls updateNSView when they change.
    let version: Int
    let selection: IndexSet
    let thumbnailSize: CGFloat
    let onOpen: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = FillingGridLayout()
        layout.targetSide = thumbnailSize

        let collectionView = GridCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.onOpen = { [weak coordinator = context.coordinator] index in coordinator?.onOpen?(index) }
        collectionView.menuProvider = { [weak coordinator = context.coordinator] in coordinator?.contextMenu() }
        collectionView.onSelectionChangedProgrammatically = { [weak coordinator = context.coordinator] in coordinator?.pushSelection() }

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor

        let coordinator = context.coordinator
        coordinator.collectionView = collectionView
        coordinator.onOpen = onOpen
        coordinator.appliedVersion = version
        coordinator.observe(scrollView)
        DispatchQueue.main.async { coordinator.scrollToEndIfNeeded() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpen = onOpen
        guard let collectionView = coordinator.collectionView else { return }
        if let layout = collectionView.collectionViewLayout as? FillingGridLayout, layout.targetSide != thumbnailSize {
            layout.targetSide = thumbnailSize
            coordinator.restoreAnchor()
            coordinator.refreshVisibleThumbnails()
        }
        coordinator.sync(to: version)
        coordinator.apply(selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let library: PhotoLibrary
        weak var collectionView: GridCollectionView?
        var onOpen: ((Int) -> Void)?
        var appliedVersion = 0
        let imageManager = PHCachingImageManager()
        let localStatus = LocalStatusCache()

        /// The item at the top of the view and how far its top edge sits from the top of the view.
        /// Kept up to date while scrolling, and restored whenever the column count changes
        /// (window or sidebar resize, the export panel opening, thumbnail zoom), so the grid
        /// doesn't jump to a different part of the library.
        private struct Anchor {
            let index: Int
            let offset: CGFloat
        }
        private var anchor: Anchor?
        private var lastClipWidth: CGFloat = 0
        private var restoring = false

        init(library: PhotoLibrary) {
            self.library = library
            imageManager.allowsCachingHighQualityImages = false
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            library.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath)
            if let cell = cell as? PhotoCell, let asset = library.asset(at: indexPath.item) {
                cell.configure(asset: asset, pixelSide: pixelSide, imageManager: imageManager, localStatus: localStatus)
            }
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection()
        }

        private var pixelSide: CGFloat {
            let side = (collectionView?.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.width ?? 150
            return side * (collectionView?.window?.backingScaleFactor ?? 2)
        }

        func pushSelection() {
            guard let collectionView else { return }
            let current = IndexSet(collectionView.selectionIndexPaths.map(\.item))
            if current != library.selection { library.selection = current }
        }

        func contextMenu() -> NSMenu? {
            let selected = library.selectedAssets
            guard !selected.isEmpty else { return nil }
            let count = selected.count
            let noun = count == 1 ? "Original" : "\(count.formatted()) Originals"
            let menu = NSMenu()
            if let first = library.selection.first {
                menu.addItem(ClosureMenuItem("Preview") { [weak self] in self?.onOpen?(first) })
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem("Export \(noun)…") {
                ExportPanel.export(selected, exporter: ExportManager.shared)
            })
            if let last = ExportPanel.lastFolder {
                menu.addItem(ClosureMenuItem("Export \(noun) to “\(last.lastPathComponent)”") {
                    ExportManager.shared.export(selected, to: last)
                })
            }
            menu.addItem(.separator())
            let smaller = count == 1 ? "Smaller Version" : "\(count.formatted()) Smaller Versions"
            menu.addItem(ClosureMenuItem("Export \(smaller)…") {
                ExportPanel.export(selected, exporter: ExportManager.shared, variant: .smaller)
            })
            return menu
        }

        func apply(selection: IndexSet) {
            guard let collectionView else { return }
            let current = IndexSet(collectionView.selectionIndexPaths.map(\.item))
            if current != selection {
                collectionView.selectionIndexPaths = Set(selection.map { IndexPath(item: $0, section: 0) })
            }
        }

        func sync(to version: Int) {
            guard let collectionView, version != appliedVersion else { return }
            defer { appliedVersion = version }

            // Apply small updates in place so thumbnails don't flash while exports download
            // originals (each finished download shows up as a "changed" asset).
            if let changes = library.changes(since: appliedVersion), !changes.isEmpty {
                var structural = 0
                var changedAll = IndexSet()
                var simple = true
                for change in changes {
                    switch change {
                    case .reset:
                        simple = false
                    case let .incremental(removed, inserted, changed):
                        if !removed.isEmpty || !inserted.isEmpty { structural += 1 }
                        changedAll.formUnion(changed)
                    }
                }
                // Only one structural change can be expressed as a single batch update.
                if simple, structural <= 1 {
                    if structural == 1, case let .incremental(removed, inserted, _)? = changes.first(where: {
                        if case let .incremental(r, i, _) = $0 { return !r.isEmpty || !i.isEmpty }
                        return false
                    }) {
                        collectionView.performBatchUpdates {
                            collectionView.deleteItems(at: Set(removed.map { IndexPath(item: $0, section: 0) }))
                            collectionView.insertItems(at: Set(inserted.map { IndexPath(item: $0, section: 0) }))
                        }
                    }
                    refreshChanged(changedAll)
                    return
                }
            }
            localStatus.removeAll()
            // SwiftUI may call this inside an animated transaction (a sidebar selection change);
            // reload without animation so the old album's cells don't fade out over the new ones.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                collectionView.reloadData()
                CATransaction.commit()
            }
            scrollToEndIfNeeded()
        }

        private func refreshChanged(_ changed: IndexSet) {
            guard let collectionView, !changed.isEmpty else { return }
            for index in changed {
                if let asset = library.asset(at: index) { localStatus.invalidate(asset.localIdentifier) }
            }
            for indexPath in collectionView.indexPathsForVisibleItems() where changed.contains(indexPath.item) {
                if let cell = collectionView.item(at: indexPath) as? PhotoCell, let asset = library.asset(at: indexPath.item) {
                    cell.refreshStatus(asset: asset, localStatus: localStatus)
                }
            }
        }

        func refreshVisibleThumbnails() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let collectionView = self.collectionView else { return }
                collectionView.layoutSubtreeIfNeeded()
                for indexPath in collectionView.indexPathsForVisibleItems() {
                    if let cell = collectionView.item(at: indexPath) as? PhotoCell, let asset = self.library.asset(at: indexPath.item) {
                        cell.configure(asset: asset, pixelSide: self.pixelSide, imageManager: self.imageManager, localStatus: self.localStatus)
                    }
                }
            }
        }

        func observe(_ scrollView: NSScrollView) {
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged(_:)),
                                                   name: NSView.frameDidChangeNotification, object: clip)
        }

        @objc private func clipBoundsChanged(_ note: Notification) {
            guard !restoring, let clip = note.object as? NSClipView, clip.bounds.width == lastClipWidth else { return }
            recordAnchor()
        }

        @objc private func clipFrameChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView, clip.bounds.width != lastClipWidth else { return }
            let first = lastClipWidth == 0
            lastClipWidth = clip.bounds.width
            if !first { restoreAnchor() }
        }

        private func recordAnchor() {
            guard let collectionView, let clip = collectionView.enclosingScrollView?.contentView else { return }
            let visible = clip.documentVisibleRect
            let probe = NSPoint(x: visible.minX + 4, y: visible.minY + 4)
            guard let indexPath = collectionView.indexPathForItem(at: probe) ?? collectionView.indexPathsForVisibleItems().min(),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            anchor = Anchor(index: indexPath.item, offset: frame.minY - visible.minY)
        }

        /// Re-lays out the grid at its new width, then scrolls so the anchor item is back where it was.
        func restoreAnchor() {
            guard let anchor else { return }
            restoring = true
            DispatchQueue.main.async { [weak self] in
                defer { self?.restoring = false }
                guard let self, let collectionView = self.collectionView,
                      let scrollView = collectionView.enclosingScrollView, anchor.index < self.library.count else { return }
                collectionView.collectionViewLayout?.invalidateLayout()
                collectionView.layoutSubtreeIfNeeded()
                guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: anchor.index, section: 0))?.frame else { return }
                let clip = scrollView.contentView
                var target = clip.bounds
                target.origin.y = frame.minY - anchor.offset
                clip.scroll(to: clip.constrainBoundsRect(target).origin)
                scrollView.reflectScrolledClipView(clip)
            }
        }

        func scrollToEndIfNeeded() {
            guard let collectionView else { return }
            let count = library.count
            guard count > 0 else { return }
            collectionView.layoutSubtreeIfNeeded()
            let target = library.scrollsToEnd ? count - 1 : 0
            collectionView.scrollToItems(at: [IndexPath(item: target, section: 0)],
                                         scrollPosition: library.scrollsToEnd ? .bottom : .top)
        }
    }
}

/// Square cells sized to fill the width exactly, aiming for `targetSide` points.
final class FillingGridLayout: NSCollectionViewFlowLayout {
    var targetSide: CGFloat = 150 {
        didSet { if oldValue != targetSide { invalidateLayout() } }
    }
    private var lastWidth: CGFloat = 0

    override init() {
        super.init()
        minimumInteritemSpacing = 2
        minimumLineSpacing = 2
        sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func prepare() {
        if let collectionView {
            let width = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
            lastWidth = width
            let available = max(40, width - sectionInset.left - sectionInset.right)
            let columns = max(1, ((available + minimumInteritemSpacing) / (targetSide + minimumInteritemSpacing)).rounded(.down))
            let side = ((available - (columns - 1) * minimumInteritemSpacing) / columns).rounded(.down)
            if itemSize.width != side { itemSize = NSSize(width: side, height: side) }
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != lastWidth
    }
}

final class GridCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var onSelectionChangedProgrammatically: (() -> Void)?

    /// Right-click acts on the selection; clicking an unselected item selects just that item first,
    /// like Finder.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            onSelectionChangedProgrammatically?()
        }
        return menuProvider?()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: point) { onOpen?(indexPath.item) }
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space or Return previews the first selected item.
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            if let first = selectionIndexPaths.map(\.item).min() {
                onOpen?(first)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// Remembers which assets have their originals on this Mac, computed off the main thread.
@MainActor
final class LocalStatusCache {
    private var values: [String: LocalState] = [:]
    private let queue = DispatchQueue(label: "local-status", qos: .utility)

    func state(for asset: PHAsset, completion: @escaping @MainActor (LocalState) -> Void) {
        let id = asset.localIdentifier
        if let known = values[id] {
            completion(known)
            return
        }
        let box = UncheckedSendable(asset)
        let options = ExportOptions.current
        queue.async {
            let state = OriginalResources.localState(of: box.value, options: options)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.values[id] = state
                    completion(state)
                }
            }
        }
    }

    func invalidate(_ id: String) { values[id] = nil }
    func removeAll() { values.removeAll() }
}

/// NSMenuItem that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
