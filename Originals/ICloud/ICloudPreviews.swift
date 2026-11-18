import AppKit
import CryptoKit
import ImageIO
import Photos

/// CPLMaster records for assets, looked up in batches: a screenful of thumbnails becomes one request
/// instead of dozens. Download links in the records are good for a while, so results are kept for
/// ten minutes.
@MainActor
final class ICloudMasters {
    static let shared = ICloudMasters()

    private var records: [String: (master: ICloudMaster, fetched: Date)] = [:]
    private var recordNames: [String: String] = [:]
    private var waiting: [String: [CheckedContinuation<ICloudMaster, Error>]] = [:]
    private var flushScheduled = false
    private static let lifetime: TimeInterval = 600
    private static let batchSize = 100

    func master(for asset: PHAsset) async throws -> ICloudMaster {
        guard ICloudWebSession.shared.account != nil else { throw ICloudError.notSignedIn }
        let id = asset.localIdentifier
        if let cached = records[id], Date().timeIntervalSince(cached.fetched) < Self.lifetime {
            return cached.master
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id, default: []].append(continuation)
            if !flushScheduled {
                flushScheduled = true
                Task { @MainActor in
                    // Let the rest of this layout pass queue up its requests first.
                    try? await Task.sleep(for: .milliseconds(30))
                    self.flush()
                }
            }
        }
    }

    private func flush() {
        flushScheduled = false
        let batch = waiting
        waiting = [:]
        guard let account = ICloudWebSession.shared.account else {
            batch.values.joined().forEach { $0.resume(throwing: ICloudError.notSignedIn) }
            return
        }

        // Local identifier → CPLMaster record name, for all of them in one call.
        let unknown = batch.keys.filter { recordNames[$0] == nil }
        if !unknown.isEmpty {
            let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: Array(unknown))
            for (id, result) in mappings {
                if case let .success(cloud) = result, let name = cloud.stringValue.split(separator: ":").last {
                    recordNames[id] = String(name)
                }
            }
        }
        var byName: [String: [String]] = [:]
        for id in batch.keys {
            guard let name = recordNames[id] else {
                batch[id]?.forEach { $0.resume(throwing: ICloudError.notInICloud) }
                continue
            }
            byName[name, default: []].append(id)
        }

        let client = ICloudPhotosClient(account: account, session: ICloudWebSession.shared.apiSession)
        let names = Array(byName.keys)
        for start in stride(from: 0, to: names.count, by: Self.batchSize) {
            let chunk = Array(names[start..<min(start + Self.batchSize, names.count)])
            Task { @MainActor in
                do {
                    let found = try await client.lookup(chunk)
                    for name in chunk {
                        for id in byName[name] ?? [] {
                            if let master = found[name] {
                                self.records[id] = (master, Date())
                                batch[id]?.forEach { $0.resume(returning: master) }
                            } else {
                                batch[id]?.forEach { $0.resume(throwing: ICloudError.notInICloud) }
                            }
                        }
                    }
                } catch {
                    if case let ICloudError.http(status, _) = error, [401, 403, 421].contains(status) {
                        ICloudWebSession.shared.sessionExpired()
                    }
                    for name in chunk {
                        for id in byName[name] ?? [] { batch[id]?.forEach { $0.resume(throwing: error) } }
                    }
                }
            }
        }
    }
}

/// Thumbnails and preview images straight from iCloud, which keeps a ~360 px thumbnail and a
/// ~2,048 px JPEG of every photo and video. Photos' own route for these goes through the same
/// downloader that limits originals to ~0.7 MB/s, so thumbnails could stay blurry for minutes.
/// Downloaded images are kept on disk so they're sharp straight away next launch.
@MainActor
final class ICloudThumbnails {
    static let shared = ICloudThumbnails()

    enum Size: String {
        case thumb = "resJPEGThumb"
        case medium = "resJPEGMed"
    }

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private let limiter = Limiter(slots: 8)
    private nonisolated static let diskLimit: Int64 = 1 << 30

    private init() {
        memory.totalCostLimit = 300 << 20
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "local.originals.Originals")/iCloudPreviews",
                                                  isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory
        Task.detached(priority: .background) { Self.trim(directory, to: Self.diskLimit) }
    }

    /// The smallest iCloud version that covers `pixelSide` (the shorter side the image must fill).
    static func size(for pixelSide: CGFloat) -> Size { pixelSide <= 420 ? .thumb : .medium }

    /// An image whose shorter side is about `pixelSide` (or as big as iCloud's version, if smaller).
    /// Returns nil when not signed in, cancelled, or iCloud has no such version.
    func image(for asset: PHAsset, pixelSide: CGFloat, size: Size? = nil) async -> NSImage? {
        let size = size ?? Self.size(for: pixelSide)
        let key = Self.key(asset.localIdentifier, size)
        let memoryKey = "\(key)-\(Int(pixelSide))" as NSString
        if let image = memory.object(forKey: memoryKey) { return image }

        let file = directory.appendingPathComponent(key + ".jpg")
        let aspect = asset.pixelWidth > 0 && asset.pixelHeight > 0
            ? CGFloat(max(asset.pixelWidth, asset.pixelHeight)) / CGFloat(min(asset.pixelWidth, asset.pixelHeight)) : 1
        let longSide = Int(pixelSide * aspect)

        if let image = await Self.decode(file, longSide: longSide) {
            memory.setObject(image, forKey: memoryKey, cost: Self.cost(image))
            return image
        }
        guard ICloudWebSession.shared.account != nil,
              let master = try? await ICloudMasters.shared.master(for: asset),
              let remote = master.files[size.rawValue] ?? master.files[Size.thumb.rawValue],
              !Task.isCancelled else { return nil }
        guard let data = try? await limiter.run({
            try await ICloudWebSession.shared.downloadSession.data(from: remote.url).0
        }), !data.isEmpty else { return nil }
        try? data.write(to: file, options: .atomic)
        guard let image = await Self.decode(file, longSide: longSide) else { return nil }
        memory.setObject(image, forKey: memoryKey, cost: Self.cost(image))
        return image
    }

    private static func key(_ localIdentifier: String, _ size: Size) -> String {
        let digest = SHA256.hash(data: Data(localIdentifier.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-\(size == .thumb ? "t" : "m")"
    }

    private static func cost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }

    /// Decodes off the main thread, scaled down to `longSide`, with the JPEG's orientation applied.
    private static func decode(_ file: URL, longSide: Int) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<NSImage?> in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return UncheckedSendable(nil) }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(longSide, 64),
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return UncheckedSendable(nil)
            }
            // Touch the file so trimming keeps recently used images.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return UncheckedSendable(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        }.value.value
    }

    /// Deletes the least recently used images once the cache passes `limit`.
    private nonisolated static func trim(_ directory: URL, to limit: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit * 8 / 10 {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

/// At most `slots` operations at once; the rest wait their turn in order.
actor Limiter {
    private var free: Int
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(slots: Int) { free = slots }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if free > 0 {
            free -= 1
        } else {
            await withCheckedContinuation { queue.append($0) }
        }
        defer {
            if queue.isEmpty { free += 1 } else { queue.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
