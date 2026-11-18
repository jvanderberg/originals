import AppKit
import AVFoundation
import Observation
import Photos

enum ExportItemState: Equatable {
    case queued
    case active
    case done
    /// The same file, with the same size, was already in the destination folder.
    case skipped
    case failed(String)
    case cancelled
}

enum ExportVariant: Sendable {
    /// The unmodified original files (several for Live Photos and RAW+JPEG).
    case original
    /// One smaller file per item: 1080p for videos (720p or 360p if that's all iCloud has),
    /// a medium JPEG for photos.
    case smaller
}

enum DownloadRoute: Sendable {
    /// Straight from iCloud's servers with the web sign-in (~30 MB/s here).
    case iCloud
    /// Through PhotoKit, which iCloud limits to ~0.7 MB/s (fast when the file is already local).
    case photos
}

/// One file being exported. A Live Photo or RAW+JPEG asset produces several items.
@Observable @MainActor
final class ExportItem: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let resource: PHAssetResource
    let kind: String
    let destination: URL
    let variant: ExportVariant
    /// For smaller versions, settled once we know which version iCloud or Photos provides.
    var filename: String
    var expectedBytes: Int64
    /// Whether the original was already on this Mac when the export was queued.
    let wasLocal: Bool?
    let setFileDates: Bool
    var route: DownloadRoute?
    /// Why the fast route wasn't used, when it was tried and failed.
    var routeNote: String?
    /// Set when a running download is stopped so it can start over on the fast route.
    @ObservationIgnored var restartRequested = false
    /// The person chose to download this one through Photos (about 0.7 MB/s) instead of signing in.
    var photosRouteChosen = false

    /// Whether the file has to come from iCloud, as opposed to being read from this Mac.
    var needsICloud: Bool { variant == .smaller || wasLocal != true }

    var state: ExportItemState = .queued
    /// 0...1 as reported by PhotoKit while it downloads the original from iCloud.
    var downloadFraction: Double = 0
    var bytesWritten: Int64 = 0
    var attempt = 0
    var retryNote: String?
    var startedAt: Date?
    var finishedAt: Date?
    var outputURL: URL?
    @ObservationIgnored var task: Task<Void, Never>?

    init(asset: PHAsset, resource: PHAssetResource, destination: URL, filename: String,
         setFileDates: Bool, variant: ExportVariant = .original) {
        self.asset = asset
        self.resource = resource
        self.variant = variant
        self.kind = variant == .smaller ? "Smaller version" : OriginalResources.label(for: resource.type)
        self.destination = destination
        self.filename = filename
        self.expectedBytes = variant == .smaller ? 0 : (resource.byteCount ?? 0)
        self.wasLocal = variant == .smaller ? nil : resource.isLocal
        self.setFileDates = setFileDates
    }

    var progress: Double {
        switch state {
        case .done, .skipped: return 1
        case .active:
            let written = expectedBytes > 0 ? min(1, Double(bytesWritten) / Double(expectedBytes)) : 0
            return max(downloadFraction, written)
        default: return 0
        }
    }

    var completedBytes: Int64 {
        switch state {
        case .done, .skipped: return expectedBytes > 0 ? expectedBytes : bytesWritten
        case .active: return Int64(progress * Double(expectedBytes))
        default: return 0
        }
    }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

struct ExportStats {
    var total = 0
    var finished = 0
    var skipped = 0
    var failed = 0
    var active = 0
    var queued = 0
    var cancelled = 0
    var totalBytes: Int64 = 0
    var completedBytes: Int64 = 0
    var remainingBytes: Int64 = 0

    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return total > 0 ? Double(finished) / Double(total) : 0
    }
}

enum ExportError: LocalizedError {
    case cannotCreate(URL)
    case noFile(String)

    var errorDescription: String? {
        switch self {
        case let .cannotCreate(url): "Couldn't create a file in \(url.deletingLastPathComponent().path)"
        case let .noFile(message): message
        }
    }
}

/// Holds a PhotoKit request ID so a cancellation handler can cancel it.
private final class RequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PHImageRequestID?
    var id: PHImageRequestID? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Observable @MainActor
final class ExportManager {
    static let shared = ExportManager()

    private(set) var items: [ExportItem] = []
    private(set) var lastDestination: URL?
    private(set) var bytesPerSecond: Double?
    private(set) var batchStartedAt: Date?
    private(set) var batchFinishedAt: Date?

    var maxConcurrent: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrent, forKey: DefaultsKey.maxConcurrent)
            pump()
        }
    }
    var isPaused = false {
        didSet { if !isPaused { pump() } else { refreshActivity() } }
    }

    @ObservationIgnored private var pending: [ExportItem] = []
    @ObservationIgnored private var running = 0
    /// Names picked for the export being planned, before its items join `items`.
    @ObservationIgnored private var planning: Set<String> = []

    /// Names that files still on their way will take. Finished, failed and cancelled items release
    /// theirs: by then the file is on disk or isn't, and the disk is checked directly.
    private var reservedPaths: Set<String> {
        var paths = planning
        for item in items where item.state == .queued || item.state == .active {
            paths.insert(item.destination.appendingPathComponent(item.filename).path.lowercased())
        }
        return paths
    }
    @ObservationIgnored private var samples: [(time: Date, bytes: Int64)] = []
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.standard.integer(forKey: DefaultsKey.maxConcurrent)
        maxConcurrent = saved > 0 ? saved : 4
    }

    var isBusy: Bool { items.contains { $0.state == .active || $0.state == .queued } }

    var stats: ExportStats {
        var s = ExportStats()
        for item in items {
            switch item.state {
            case .cancelled:
                s.cancelled += 1
                continue
            case .queued:
                s.queued += 1
                s.remainingBytes += item.expectedBytes
            case .active:
                s.active += 1
                s.remainingBytes += max(0, item.expectedBytes - item.completedBytes)
            case .done:
                s.finished += 1
            case .skipped:
                s.finished += 1
                s.skipped += 1
                s.total += 1
                continue
            case .failed:
                s.failed += 1
            }
            s.total += 1
            s.totalBytes += item.expectedBytes
            s.completedBytes += item.completedBytes
        }
        return s
    }

    // MARK: Queueing

    func export(_ assets: [PHAsset], to destination: URL, variant: ExportVariant = .original,
                options: ExportOptions = .current) {
        lastDestination = destination
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        removeStalePartials(in: destination)
        planning = []
        defer { planning = [] }
        var added: [ExportItem] = []
        for asset in assets {
            let resources = OriginalResources.resources(for: asset, options: options)
            guard !resources.isEmpty else { continue }
            if variant == .smaller {
                // One file per item; its final name (and extension) is set once the version is known.
                let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources[0]
                let base = (primary.originalFilename as NSString).deletingPathExtension
                added.append(ExportItem(asset: asset, resource: primary, destination: destination,
                                        filename: "\(base) (smaller)", setFileDates: options.setFileDates,
                                        variant: .smaller))
                continue
            }
            for (resource, plan) in zip(resources, planNames(for: resources, in: destination)) {
                let item = ExportItem(asset: asset, resource: resource, destination: destination,
                                      filename: plan.name, setFileDates: options.setFileDates)
                if plan.alreadyThere {
                    item.state = .skipped
                    item.outputURL = destination.appendingPathComponent(plan.name)
                }
                added.append(item)
            }
        }
        if !isBusy {
            batchStartedAt = Date()
            batchFinishedAt = nil
        }
        items.append(contentsOf: added)
        pending.append(contentsOf: added.filter { $0.state == .queued })
        pump()
        askToSignInIfNeeded()
    }

    // MARK: Waiting for iCloud sign-in

    /// Files that have to come from iCloud don't start until the app is signed in to iCloud, because
    /// through Photos they crawl at about 0.7 MB/s. They wait in the queue until the person signs in
    /// or explicitly chooses Photos for them (`downloadWaitingThroughPhotos`).
    func isWaitingForSignIn(_ item: ExportItem) -> Bool {
        item.state == .queued && item.needsICloud && !item.photosRouteChosen
            && ICloudWebSession.shared.account == nil
    }

    var waitingForSignIn: [ExportItem] { items.filter(isWaitingForSignIn) }

    /// Downloads the waiting files through Photos instead of signing in.
    func downloadWaitingThroughPhotos() {
        for item in waitingForSignIn { item.photosRouteChosen = true }
        pump()
    }

    /// Called by `ICloudWebSession` whenever the sign-in is checked, made, lost or removed.
    func signInStateChanged() {
        if ICloudWebSession.shared.account != nil {
            moveSlowDownloadsToICloud()
        } else {
            askToSignInIfNeeded()
        }
        pump()
    }

    /// Opens the sign-in sheet when files are waiting for it. While the launch check of a saved
    /// sign-in is still running, waits for its result instead (it calls `signInStateChanged`).
    private func askToSignInIfNeeded() {
        let icloud = ICloudWebSession.shared
        switch icloud.state {
        case .signedOut, .failed: break
        case .unknown, .checking, .signedIn: return
        }
        if !icloud.isSignInPresented, !waitingForSignIn.isEmpty { icloud.isSignInPresented = true }
    }

    /// Temp files (".IMG_1234.MOV.1A2B3C4D.partial") left behind when the app was quit or crashed
    /// mid-download. Only names in exactly that form, and not belonging to a running item, are removed.
    private func removeStalePartials(in folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let live = Set(items.filter { $0.state == .queued || $0.state == .active }.map { String($0.id.uuidString.prefix(8)) })
        let pattern = /^\..+\.([0-9A-F]{8})\.partial$/
        for name in names {
            guard let match = name.wholeMatch(of: pattern), !live.contains(String(match.1)) else { continue }
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Picks file names for one asset's resources. Files that belong together (a Live Photo's
    /// HEIC and MOV) get the same " (n)" suffix so they still pair up after a name collision.
    private func planNames(for resources: [PHAssetResource], in folder: URL) -> [(name: String, alreadyThere: Bool)] {
        let fm = FileManager.default
        var bases: [String] = []
        for resource in resources {
            var name = resource.originalFilename.isEmpty ? "Untitled" : resource.originalFilename
            var n = 2
            while bases.contains(where: { $0.lowercased() == name.lowercased() }) {
                name = Self.suffixed(resource.originalFilename, n)
                n += 1
            }
            bases.append(name)
        }

        func key(_ name: String) -> String { folder.appendingPathComponent(name).path.lowercased() }

        let alreadyExported = zip(bases, resources).allSatisfy { name, resource in
            guard let expected = resource.byteCount, !reservedPaths.contains(key(name)),
                  let attrs = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path),
                  let size = attrs[.size] as? NSNumber else { return false }
            return size.int64Value == expected
        }
        if alreadyExported { return bases.map { ($0, true) } }

        var n = 0
        while true {
            let names = n == 0 ? bases : bases.map { Self.suffixed($0, n) }
            let taken = names.contains { reservedPaths.contains(key($0)) || fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            if !taken {
                names.forEach { planning.insert(key($0)) }
                return names.map { ($0, false) }
            }
            n += 1
        }
    }

    private static func suffixed(_ name: String, _ n: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
    }

    // MARK: Controls

    func cancelAll() {
        for item in pending where item.state == .queued { item.state = .cancelled }
        pending.removeAll()
        for item in items where item.state == .active { item.task?.cancel() }
        isPaused = false
        refreshActivity()
    }

    func cancel(_ item: ExportItem) {
        switch item.state {
        case .queued:
            item.state = .cancelled
            pending.removeAll { $0 === item }
            refreshActivity()
        case .active:
            item.task?.cancel()
        default:
            break
        }
    }

    func retry(_ item: ExportItem) {
        switch item.state {
        case .failed, .cancelled: break
        default: return
        }
        item.state = .queued
        item.attempt = 0
        item.retryNote = nil
        item.route = nil
        item.routeNote = nil
        item.downloadFraction = 0
        item.bytesWritten = 0
        item.startedAt = nil
        item.finishedAt = nil
        if !isBusy {
            batchStartedAt = Date()
            batchFinishedAt = nil
        }
        pending.append(item)
        pump()
    }

    func retryFailed() {
        for item in items {
            if case .failed = item.state { retry(item) }
        }
    }

    /// Stopped on purpose to move to the fast route: back to the front of the queue.
    private func requeueForRestart(_ item: ExportItem) {
        item.restartRequested = false
        item.route = nil
        item.routeNote = nil
        item.retryNote = nil
        item.attempt = 0
        item.downloadFraction = 0
        item.bytesWritten = 0
        item.startedAt = nil
        item.state = .queued
        pending.insert(item, at: 0)
        askToSignInIfNeeded()
    }

    /// After signing in to iCloud: restart files that are crawling through Photos on the direct route.
    /// Files already on this Mac stay on Photos, which is fast for them.
    func moveSlowDownloadsToICloud() {
        guard ICloudWebSession.shared.account != nil else { return }
        for item in items where item.state == .active && item.route == .photos && item.routeNote == nil
            && (item.variant == .smaller || item.wasLocal != true) {
            item.restartRequested = true
            item.task?.cancel()
        }
    }

    func clearFinished() {
        items.removeAll { [.done, .skipped, .cancelled].contains($0.state) }
    }

    // MARK: Running

    private func pump() {
        pending.removeAll { $0.state != .queued }
        while !isPaused, running < maxConcurrent,
              let index = pending.firstIndex(where: { !isWaitingForSignIn($0) }) {
            let item = pending.remove(at: index)
            running += 1
            item.state = .active
            item.startedAt = Date()
            item.task = Task { [weak self] in
                await self?.run(item)
                guard let self else { return }
                self.running -= 1
                self.pump()
            }
        }
        refreshActivity()
    }

    private func run(_ item: ExportItem) async {
        let maxAttempts = 3
        while true {
            item.attempt += 1
            item.downloadFraction = 0
            item.bytesWritten = 0
            do {
                item.outputURL = try await write(item)
                item.retryNote = nil
                item.state = .done
                item.finishedAt = Date()
                return
            } catch {
                if item.restartRequested {
                    requeueForRestart(item)
                    return
                }
                if Task.isCancelled || error is CancellationError {
                    item.state = .cancelled
                    item.finishedAt = Date()
                    return
                }
                let message = Self.describe(error)
                if item.attempt < maxAttempts {
                    let delay = pow(2.0, Double(item.attempt))
                    item.retryNote = "Attempt \(item.attempt) failed (\(message)). Retrying in \(Int(delay))s"
                    try? await Task.sleep(for: .seconds(delay))
                    if item.restartRequested {
                        requeueForRestart(item)
                        return
                    }
                    if Task.isCancelled {
                        item.state = .cancelled
                        item.finishedAt = Date()
                        return
                    }
                    item.retryNote = "Attempt \(item.attempt + 1) of \(maxAttempts)"
                    continue
                }
                item.state = .failed(message)
                item.finishedAt = Date()
                return
            }
        }
    }

    /// Downloads into a hidden temp file in the destination, then renames it into place.
    /// Signed in to iCloud, files not already on this Mac come straight from iCloud; if that fails for
    /// any reason other than cancelling, the item falls back to Photos.
    private func write(_ item: ExportItem) async throws -> URL {
        let fm = FileManager.default
        let tempURL = item.destination.appendingPathComponent(".\(item.filename).\(item.id.uuidString.prefix(8)).partial")
        try? fm.removeItem(at: tempURL)
        defer { try? fm.removeItem(at: tempURL) }

        var done = false
        if let account = ICloudWebSession.shared.account, item.variant == .smaller || item.wasLocal != true {
            item.route = .iCloud
            do {
                try await writeFromICloud(item, account: account, to: tempURL)
                done = true
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if case let ICloudError.http(status, _) = error, [401, 403, 421].contains(status) {
                    // The sign-in ran out: wait for a new one rather than drop to Photos' speed.
                    item.restartRequested = true
                    ICloudWebSession.shared.sessionExpired()
                    throw error
                }
                item.routeNote = "Direct download failed (\(Self.describe(error))), so this one came through Photos"
                item.bytesWritten = 0
                item.downloadFraction = 0
                try? fm.removeItem(at: tempURL)
            }
        }
        if !done {
            item.route = .photos
            switch item.variant {
            case .original: try await writeOriginalFromPhotos(item, to: tempURL)
            case .smaller: try await writeSmallerFromPhotos(item, to: tempURL)
            }
        }
        return try moveIntoPlace(item, from: tempURL)
    }

    // MARK: iCloud route


    private func writeFromICloud(_ item: ExportItem, account: ICloudAccount, to tempURL: URL) async throws {
        let master = try await masterRecord(for: item.asset, account: account)
        let file: ICloudFile
        switch item.variant {
        case .original:
            guard let field = ICloudRendition.original(for: item.resource.type), let original = master.files[field] else {
                throw ICloudError.unexpectedResponse("no original file in the record")
            }
            // Same file as Photos has, or don't trust it.
            if let expected = item.resource.byteCount, expected != original.size {
                throw ICloudError.sizeMismatch(expected: expected, actual: original.size)
            }
            file = original
        case .smaller:
            let choices = item.asset.mediaType == .video ? ICloudRendition.smallerVideo : ICloudRendition.smallerPhoto
            guard let pick = choices.first(where: { master.files[$0.field] != nil }),
                  let rendition = master.files[pick.field] else { throw ICloudError.noSuchVersion }
            file = rendition
            item.expectedBytes = rendition.size
            item.filename = Self.smallerName(item, label: pick.label, extension: rendition.fileExtension)
        }
        let downloader = RangedDownloader(session: ICloudWebSession.shared.downloadSession)
        try await downloader.download(file.url, size: file.size, to: tempURL) { bytes in
            Task { @MainActor in item.bytesWritten = bytes }
        }
        item.bytesWritten = file.size
    }

    /// Lookups are cached briefly so a Live Photo's two files share one, and download links stay fresh.
    private func masterRecord(for asset: PHAsset, account: ICloudAccount) async throws -> ICloudMaster {
        try await ICloudMasters.shared.master(for: asset)
    }

    private static func smallerName(_ item: ExportItem, label: String, extension ext: String) -> String {
        let base = (item.resource.originalFilename as NSString).deletingPathExtension
        return "\(base) (\(label)).\(ext)"
    }

    // MARK: Photos route

    /// The smaller version Photos provides: its medium-quality video, or a 2048 px JPEG of a photo.
    private func writeSmallerFromPhotos(_ item: ExportItem, to tempURL: URL) async throws {
        let manager = PHImageManager.default()
        let requestBox = RequestIDBox()
        if item.asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .mediumQualityFormat
            DownloadIntent.edit.apply(to: options)
            options.progressHandler = { progress, _, _, _ in
                Task { @MainActor in item.downloadFraction = progress }
            }
            let result: UncheckedSendable<AVAsset?> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    requestBox.id = manager.requestAVAsset(forVideo: item.asset, options: options) { asset, _, _ in
                        continuation.resume(returning: UncheckedSendable(asset))
                    }
                }
            } onCancel: {
                if let id = requestBox.id { PHImageManager.default().cancelImageRequest(id) }
            }
            try Task.checkCancellation()
            guard let url = (result.value as? AVURLAsset)?.url, url.isFileURL else {
                throw ExportError.noFile("Photos didn't provide a smaller file for this video")
            }
            try FileManager.default.copyItem(at: url, to: tempURL)
            item.filename = Self.smallerName(item, label: "smaller", extension: url.pathExtension.uppercased())
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            DownloadIntent.edit.apply(to: options)
            options.progressHandler = { progress, _, _, _ in
                Task { @MainActor in item.downloadFraction = progress }
            }
            let result: UncheckedSendable<NSImage?> = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    requestBox.id = manager.requestImage(for: item.asset, targetSize: CGSize(width: 2048, height: 2048),
                                                         contentMode: .aspectFit, options: options) { image, _ in
                        continuation.resume(returning: UncheckedSendable(image))
                    }
                }
            } onCancel: {
                if let id = requestBox.id { PHImageManager.default().cancelImageRequest(id) }
            }
            try Task.checkCancellation()
            guard let cgImage = result.value?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                throw ExportError.noFile("Photos didn't provide an image for this item")
            }
            try jpeg.write(to: tempURL)
            item.filename = Self.smallerName(item, label: "medium", extension: "JPG")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        item.expectedBytes = size
        item.bytesWritten = size
    }

    /// Streams the original through PhotoKit's resource manager.
    private func writeOriginalFromPhotos(_ item: ExportItem, to tempURL: URL) async throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: tempURL.path, contents: nil) else { throw ExportError.cannotCreate(tempURL) }

        let sink = try DataSink(url: tempURL)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        DownloadIntent.edit.apply(to: options)
        options.progressHandler = { fraction in
            Task { @MainActor in item.downloadFraction = fraction }
        }
        let resource = UncheckedSendable(item.resource)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    sink.setContinuation(continuation)
                    let requestID = PHAssetResourceManager.default().requestData(
                        for: resource.value, options: options,
                        dataReceivedHandler: { data in
                            if let written = sink.append(data) {
                                Task { @MainActor in item.bytesWritten = written }
                            }
                        },
                        completionHandler: { error in
                            sink.finish(error: error ?? sink.writeError)
                        }
                    )
                    sink.setRequest(requestID)
                }
            } onCancel: {
                sink.cancel()
            }
            try sink.close()
        } catch {
            try? sink.close()
            throw Task.isCancelled ? CancellationError() : error
        }
        item.bytesWritten = sink.bytesWritten
    }

    private func moveIntoPlace(_ item: ExportItem, from tempURL: URL) throws -> URL {
        let fm = FileManager.default
        var finalURL = item.destination.appendingPathComponent(item.filename)
        var n = 1
        while fm.fileExists(atPath: finalURL.path) {
            finalURL = item.destination.appendingPathComponent(Self.suffixed(item.filename, n))
            n += 1
        }
        try fm.moveItem(at: tempURL, to: finalURL)
        if item.setFileDates, let date = item.asset.creationDate {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: finalURL.path)
        }
        return finalURL
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = ns.localizedDescription
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.localizedDescription))"
        }
        return "\(text) [\(ns.domain) \(ns.code)]"
    }

    // MARK: Activity, speed, dock badge

    private func refreshActivity() {
        let working = running > 0 || (!isPaused && pending.contains { !isWaitingForSignIn($0) })
        if working, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Exporting originals from Photos")
            startSampler()
        } else if !working, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            stopSampler()
            if !isBusy {
                batchFinishedAt = Date()
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    private func startSampler() {
        samples = []
        bytesPerSecond = nil
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopSampler() {
        sampler?.cancel()
        sampler = nil
        bytesPerSecond = nil
        NSApp.dockTile.badgeLabel = nil
    }

    private func sample() {
        let s = stats
        let now = Date()
        // A file that restarts (say, moving from Photos to iCloud) loses its progress; start the
        // average over from there rather than let the drop cancel out real downloading.
        if let last = samples.last, s.completedBytes < last.bytes { samples = [] }
        samples.append((now, s.completedBytes))
        samples.removeAll { now.timeIntervalSince($0.time) > 20 }
        if let first = samples.first, let last = samples.last {
            let span = last.time.timeIntervalSince(first.time)
            if span >= 3 { bytesPerSecond = max(0, Double(last.bytes - first.bytes) / span) }
        }
        NSApp.dockTile.badgeLabel = "\(Int(s.fraction * 100))%"
    }
}

/// Receives PhotoKit's data callbacks on its private queue and writes them to disk.
/// Resumes the waiting continuation exactly once, whether the request finishes, fails, or is cancelled.
private final class DataSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var bytes: Int64 = 0
    private var error: Error?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var closed = false
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    func setContinuation(_ c: CheckedContinuation<Void, Error>) {
        lock.withLock { continuation = c }
    }

    var bytesWritten: Int64 { lock.withLock { bytes } }
    var writeError: Error? { lock.withLock { error } }

    /// Returns the running byte count when the UI should be updated (about 10 times a second).
    func append(_ data: Data) -> Int64? {
        lock.lock()
        guard error == nil, !cancelled, !closed else {
            lock.unlock()
            return nil
        }
        do {
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
        } catch {
            self.error = error
            let id = requestID
            lock.unlock()
            if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
            return nil
        }
        let now = Date()
        var report: Int64?
        if now.timeIntervalSince(lastReport) > 0.1 {
            lastReport = now
            report = bytes
        }
        lock.unlock()
        return report
    }

    func setRequest(_ id: PHAssetResourceDataRequestID) {
        let alreadyCancelled = lock.withLock {
            requestID = id
            return cancelled
        }
        if alreadyCancelled { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancel() {
        let id: PHAssetResourceDataRequestID? = lock.withLock {
            cancelled = true
            return requestID
        }
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        finish(error: CancellationError())
    }

    func finish(error: Error?) {
        let pending: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }

    func close() throws {
        let shouldClose = lock.withLock {
            defer { closed = true }
            return !closed
        }
        if shouldClose { try handle.close() }
    }
}
