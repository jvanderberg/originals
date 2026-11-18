import Foundation
import Photos

/// Wraps a non-Sendable value so it can cross into a background task.
/// Only used for PhotoKit objects, which are safe to read from any thread.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum DefaultsKey {
    static let includeLivePhotoVideo = "includeLivePhotoVideo"
    static let includeRAW = "includeRAW"
    static let setFileDates = "setFileDates"
    static let maxConcurrent = "maxConcurrent"
    static let lastExportFolder = "lastExportFolder"
    static let thumbnailSize = "thumbnailSize"
}

struct ExportOptions: Sendable {
    var includeLivePhotoVideo = true
    var includeRAW = true
    var setFileDates = true

    static var current: ExportOptions {
        let d = UserDefaults.standard
        return ExportOptions(
            includeLivePhotoVideo: d.object(forKey: DefaultsKey.includeLivePhotoVideo) as? Bool ?? true,
            includeRAW: d.object(forKey: DefaultsKey.includeRAW) as? Bool ?? true,
            setFileDates: d.object(forKey: DefaultsKey.setFileDates) as? Bool ?? true
        )
    }
}

enum LocalState: Sendable {
    case local, cloud, unknown
}

enum OriginalResources {
    /// The files that make up the unmodified original of an asset: the photo or video itself,
    /// the RAW/JPEG partner of a RAW+JPEG pair, and the video half of a Live Photo.
    /// Edited renders and adjustment data are left out.
    static func resources(for asset: PHAsset, options: ExportOptions) -> [PHAssetResource] {
        let all = PHAssetResource.assetResources(for: asset)
        let originals = all.filter { resource in
            switch resource.type {
            case .photo, .video, .audio: return true
            case .alternatePhoto: return options.includeRAW
            case .pairedVideo: return options.includeLivePhotoVideo
            default: return false
            }
        }
        if !originals.isEmpty { return originals }
        // Some assets (rare: certain shared or imported items) only carry a full-size render.
        return all.filter { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
    }

    static func localState(of asset: PHAsset, options: ExportOptions) -> LocalState {
        var sawUnknown = false
        for resource in resources(for: asset, options: options) {
            switch resource.isLocal {
            case .some(false): return .cloud
            case .none: sawUnknown = true
            case .some(true): break
            }
        }
        return sawUnknown ? .unknown : .local
    }

    static func label(for type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .alternatePhoto: "Alternate photo (RAW/JPEG)"
        case .pairedVideo: "Live Photo video"
        case .fullSizePhoto: "Full-size photo"
        case .fullSizeVideo: "Full-size video"
        default: "Resource"
        }
    }
}

extension PHAssetResource {
    // PhotoKit has no public API for these, but PHAssetResource answers to `fileSize` and
    // `isLocallyAvailable`. Check before asking so a future OS that drops them returns nil
    // instead of raising an exception.

    /// Size of the original file in bytes, if PhotoKit knows it.
    var byteCount: Int64? {
        guard responds(to: NSSelectorFromString("fileSize")) else { return nil }
        return (value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// Whether the original bytes are already on this Mac (false means it lives only in iCloud).
    var isLocal: Bool? {
        guard responds(to: NSSelectorFromString("isLocallyAvailable")) else { return nil }
        return (value(forKey: "locallyAvailable") as? NSNumber)?.boolValue
    }
}

extension Int64 {
    var byteString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
        return formatter.string(fromByteCount: self)
    }
}

func durationString(_ seconds: TimeInterval) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: max(0, seconds)) ?? ""
}

func clockString(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// PhotoKit's default download intent ("unknown") is one CloudPhotoLibrary runs as a throttled
/// background transfer: CloudKit QoS background, discretionary. Measured ~0.7 MB/s on a 280 Mbps link.
/// The "edit", "one-up" and "grid" intents are not on CPL's background list
/// (CPLResourceTransferTaskOptions.intentsToBackgroundDownload) and run at user-initiated QoS.
///
/// PhotoKit numbers these differently from CloudPhotoLibrary. The values below come from the names
/// PHImageRequestOptions prints in its debugDescription for each `downloadIntent` value:
///   1 widget, 2 grid, 3 one-up, 4 edit, 5 memory, 6 analysis, 7 watch-sync, 8 wallpaper-suggestion, ...
/// photolibraryd logs the intent it received ("options: intent edit priority on-demand"),
/// which is how to confirm it took effect.
///
/// These are private properties on the public options classes, so check before setting.
enum DownloadIntent: Int {
    case grid = 2
    case oneUp = 3
    case edit = 4

    func apply(to options: NSObject) {
        guard options.responds(to: NSSelectorFromString("setDownloadIntent:")) else { return }
        options.setValue(rawValue, forKey: "downloadIntent")
        if options.responds(to: NSSelectorFromString("setDownloadPriority:")) {
            options.setValue(0, forKey: "downloadPriority") // 0 = on-demand, the most urgent
        }
    }
}
