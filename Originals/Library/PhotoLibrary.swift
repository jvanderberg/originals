import AppKit
import Observation
import Photos

enum Source: Hashable {
    case allPhotos
    /// `sortByDate` is true for smart albums (shown oldest to newest like Photos) and false for
    /// user albums, which keep their own order.
    case collection(id: String, sortByDate: Bool)
}

struct SidebarNode: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    /// nil for folders, which only group albums.
    let source: Source?
    var children: [SidebarNode]?
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos"
    var id: Self { self }
}

/// How the asset list changed, so the grid can update in place instead of reloading.
enum GridChange {
    case reset
    case incremental(removed: IndexSet, inserted: IndexSet, changed: IndexSet)
}

struct SelectionSummary: Equatable {
    var assets = 0
    var files = 0
    var bytes: Int64 = 0
    var cloudOnly = 0
}

@Observable @MainActor
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var libraryNodes: [SidebarNode] = []
    private(set) var albumNodes: [SidebarNode] = []
    private(set) var sharedNodes: [SidebarNode] = []

    var source: Source? = .allPhotos {
        didSet { if source != oldValue, source != nil { reload() } }
    }
    var mediaFilter: MediaFilter = .all {
        didSet { if mediaFilter != oldValue { reload() } }
    }

    private(set) var sourceTitle = "Library"
    private(set) var assets: PHFetchResult<PHAsset>?
    /// Bumped on every change to `assets`; the grid compares it to decide what to update.
    private(set) var assetsVersion = 0
    /// Date-sorted views open scrolled to the newest item, like Photos.
    private(set) var scrollsToEnd = true

    var selection = IndexSet() {
        didSet { if selection != oldValue { scheduleSummary() } }
    }
    private(set) var selectionSummary: SelectionSummary?

    @ObservationIgnored private var changeLog: [(version: Int, change: GridChange)] = []
    @ObservationIgnored private var topLevelCollections: PHFetchResult<PHCollection>?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    override init() {
        super.init()
        if isAuthorized { start() }
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }

    var count: Int { assets?.count ?? 0 }

    func asset(at index: Int) -> PHAsset? {
        guard let assets, index >= 0, index < assets.count else { return nil }
        return assets.object(at: index)
    }

    var selectedAssets: [PHAsset] {
        guard let assets else { return [] }
        let valid = selection.filteredIndexSet { $0 < assets.count }
        return assets.objects(at: valid)
    }

    // MARK: Access

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if isAuthorized { start() }
    }

    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status != authorization else { return }
        authorization = status
        if isAuthorized { start() }
    }

    private func start() {
        guard !started else { return }
        started = true
        PHPhotoLibrary.shared().register(self)
        buildSidebar()
        reload()
    }

    // MARK: Fetching

    private func reload() {
        guard started else { return }
        let options = PHFetchOptions()
        switch mediaFilter {
        case .all: break
        case .photos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        let byDate = [NSSortDescriptor(key: "creationDate", ascending: true)]

        switch source ?? .allPhotos {
        case .allPhotos:
            options.sortDescriptors = byDate
            assets = PHAsset.fetchAssets(with: options)
            sourceTitle = "Library"
            scrollsToEnd = true
        case let .collection(id, sortByDate):
            if sortByDate { options.sortDescriptors = byDate }
            if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                assets = PHAsset.fetchAssets(in: collection, options: options)
                sourceTitle = collection.localizedTitle ?? "Album"
            } else {
                assets = nil
                sourceTitle = "Album"
            }
            scrollsToEnd = sortByDate
        }
        selection = []
        record(.reset)
    }

    private func record(_ change: GridChange) {
        assetsVersion += 1
        changeLog.append((assetsVersion, change))
        if changeLog.count > 64 { changeLog.removeFirst(changeLog.count - 64) }
    }

    /// Changes after `version`, in order, or nil if some were dropped (caller should reload).
    func changes(since version: Int) -> [GridChange]? {
        let pending = changeLog.filter { $0.version > version }
        guard let first = pending.first, first.version == version + 1 else { return nil }
        return pending.map(\.change)
    }

    // MARK: Sidebar

    private func buildSidebar() {
        var nodes = [SidebarNode(id: "all", title: "Library", symbol: "photo.on.rectangle", source: .allPhotos)]
        let smart: [(PHAssetCollectionSubtype, String)] = [
            (.smartAlbumFavorites, "heart"),
            (.smartAlbumRecentlyAdded, "clock"),
            (.smartAlbumVideos, "video"),
            (.smartAlbumLivePhotos, "livephoto"),
            (.smartAlbumSelfPortraits, "person.crop.square"),
            (.smartAlbumPanoramas, "pano"),
            (.smartAlbumSlomoVideos, "slowmo"),
            (.smartAlbumTimelapses, "timelapse"),
            (.smartAlbumBursts, "square.stack.3d.down.right"),
            (.smartAlbumScreenshots, "camera.viewfinder"),
            (.smartAlbumRAW, "camera.aperture"),
            (.smartAlbumAnimated, "square.stack.3d.forward.dottedline"),
        ]
        for (subtype, symbol) in smart {
            guard let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).firstObject else { continue }
            let probe = PHFetchOptions()
            probe.fetchLimit = 1
            guard PHAsset.fetchAssets(in: collection, options: probe).count > 0 else { continue }
            // Recently Added is ordered by when items were added, so keep its native order.
            let sortByDate = subtype != .smartAlbumRecentlyAdded
            nodes.append(SidebarNode(id: collection.localIdentifier, title: collection.localizedTitle ?? "Album",
                                     symbol: symbol, source: .collection(id: collection.localIdentifier, sortByDate: sortByDate)))
        }
        libraryNodes = nodes

        let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        topLevelCollections = topLevel
        albumNodes = Self.nodes(for: topLevel)

        var shared: [SidebarNode] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil).enumerateObjects { album, _, _ in
            shared.append(SidebarNode(id: album.localIdentifier, title: album.localizedTitle ?? "Shared Album",
                                      symbol: "person.2", source: .collection(id: album.localIdentifier, sortByDate: false)))
        }
        sharedNodes = shared
    }

    private static func nodes(for collections: PHFetchResult<PHCollection>) -> [SidebarNode] {
        var result: [SidebarNode] = []
        collections.enumerateObjects { collection, _, _ in
            if let album = collection as? PHAssetCollection {
                result.append(SidebarNode(id: album.localIdentifier, title: album.localizedTitle ?? "Album",
                                          symbol: "rectangle.stack", source: .collection(id: album.localIdentifier, sortByDate: false)))
            } else if let folder = collection as? PHCollectionList {
                let children = nodes(for: PHCollection.fetchCollections(in: folder, options: nil))
                result.append(SidebarNode(id: folder.localIdentifier, title: folder.localizedTitle ?? "Folder",
                                          symbol: "folder", source: nil, children: children))
            }
        }
        return result
    }

    // MARK: Changes

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let change = UncheckedSendable(changeInstance)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.apply(change.value) }
        }
    }

    private func apply(_ change: PHChange) {
        if let assets, let details = change.changeDetails(for: assets) {
            self.assets = details.fetchResultAfterChanges
            if details.hasIncrementalChanges, !details.hasMoves {
                let removed = details.removedIndexes ?? []
                let inserted = details.insertedIndexes ?? []
                let changed = details.changedIndexes ?? []
                var adjusted = selection
                for index in removed.reversed() {
                    adjusted.remove(index)
                    adjusted.shift(startingAt: index + 1, by: -1)
                }
                for index in inserted { adjusted.shift(startingAt: index, by: 1) }
                record(.incremental(removed: removed, inserted: inserted, changed: changed))
                if adjusted != selection {
                    selection = adjusted
                } else if !changed.isEmpty, !selection.intersection(changed).isEmpty {
                    scheduleSummary() // a selected item finished downloading
                }
            } else {
                record(.reset)
                selection = []
            }
        }
        if let topLevelCollections, change.changeDetails(for: topLevelCollections) != nil {
            buildSidebar()
        }
    }

    // MARK: Selection summary

    private func scheduleSummary() {
        summaryTask?.cancel()
        let picked = selectedAssets
        guard !picked.isEmpty else {
            selectionSummary = nil
            return
        }
        selectionSummary = nil
        let box = UncheckedSendable(picked)
        let options = ExportOptions.current
        summaryTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var summary = SelectionSummary(assets: box.value.count)
            for (n, asset) in box.value.enumerated() {
                if n % 200 == 0, Task.isCancelled { return }
                var inCloud = false
                for resource in OriginalResources.resources(for: asset, options: options) {
                    summary.files += 1
                    summary.bytes += resource.byteCount ?? 0
                    if resource.isLocal == false { inCloud = true }
                }
                if inCloud { summary.cloudOnly += 1 }
            }
            guard !Task.isCancelled else { return }
            let result = summary
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.selectionSummary = result
            }
        }
    }
}
