#if DEBUG
import AppKit
import AVFoundation
import Photos
import WebKit

/// Phase 1 of the download-path investigation: for a large iCloud-only video, what does PhotoKit's
/// playback path return? A remote URL we can fetch ourselves (in parallel ranges), or only a local
/// file after the same throttled download?
@MainActor
final class HeadlessProbe {
    private let workDir: URL
    private let logHandle: FileHandle
    private let started = Date()

    static func main(workDir: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let probe = HeadlessProbe(workDir: workDir)
        Task { @MainActor in
            await probe.run()
            probe.say("done")
            exit(0)
        }
        app.run()
        exit(0)
    }

    init(workDir: URL) {
        self.workDir = workDir
        let logURL = workDir.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try! FileHandle(forWritingTo: logURL)
    }

    func say(_ text: String) {
        let line = String(format: "[%7.1fs] ", Date().timeIntervalSince(started)) + text + "\n"
        logHandle.write(line.data(using: .utf8)!)
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
    }

    func run() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        say("photos authorization: \(status.rawValue)")
        guard status == .authorized else { return }

        guard let (asset, resource) = pickVideo() else {
            say("no iCloud-only video between 1 and 3 GB found")
            return
        }
        say("target: \(resource.originalFilename) \(resource.byteCount ?? -1) bytes, \(asset.pixelWidth)x\(asset.pixelHeight), \(String(format: "%.1f", asset.duration))s, local=\(String(describing: resource.isLocal)) id=\(asset.localIdentifier)")

        let mode = ProcessInfo.processInfo.environment["ORIGINALS_PROBE_MODE"] ?? "stream"
        say("mode: \(mode)")
        switch mode {
        case "stream":
            await probeStream(asset)
        case "oneup":
            await probePlayerItem(asset, limit: 35)
        case "fastexport":
            await probeFastExport(video: asset)
        case "switchroute":
            await probeSwitchRoute(video: asset)
        case "persisttest":
            await probePersist(video: asset)
        case "renditions":
            await probeRenditions(video: asset)
        case "launchsignin":
            let t0 = Date()
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            say("WebKit cookies: \(cookies.count) after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s, auth: \(cookies.contains { $0.name == "X-APPLE-WEBAUTH-TOKEN" })")
            for c in cookies where c.name.hasPrefix("X-APPLE-WEBAUTH-TOKEN") || c.name == "X-APPLE-DS-WEB-SESSION-TOKEN" {
                say("  \(c.name) domain \(c.domain) session \(c.isSessionOnly) expires \(c.expiresDate.map { "\($0)" } ?? "-")")
            }
            await ICloudWebSession.shared.refresh()
            say("state after refresh: \(ICloudWebSession.shared.state)")
        case "signinpage":
            await probeSignInPage()
        case "cloudid":
            probeCloudID(asset)
        case "derivative":
            await probeDerivative(asset, quality: ProcessInfo.processInfo.environment["ORIGINALS_PROBE_QUALITY"] ?? "medium")
        default:
            say("unknown mode")
        }
    }

    /// What the preview does: default version and delivery mode, which plays from a stream.
    private func probeStream(_ asset: PHAsset) async {
        let env = ProcessInfo.processInfo.environment
        let wantOriginal = env["ORIGINALS_PROBE_VERSION"] != "current"
        say("--- requestPlayerItem(streamingAllowed, streamingVideoIntent=user, version \(wantOriginal ? "original" : "current"))")
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = wantOriginal ? .original : .current
        options.deliveryMode = .highQualityFormat
        options.setValue(true, forKey: "streamingAllowed")
        options.setValue(1, forKey: "streamingVideoIntent") // 1 = "user"
        DownloadIntent.oneUp.apply(to: options)
        say("options: \(options.debugDescription)")
        let t0 = Date()
        let result: UncheckedSendable<(AVPlayerItem?, [AnyHashable: Any]?)> = await withCheckedContinuation { c in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                c.resume(returning: UncheckedSendable((item, info)))
            }
        }
        say("returned after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        describe(result.value.0?.asset, info: result.value.1)
        if let avAsset = result.value.0?.asset {
            let tracks = (try? await avAsset.loadTracks(withMediaType: .video)) ?? []
            for track in tracks {
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let rate = (try? await track.load(.estimatedDataRate)) ?? 0
                let codecs = ((try? await track.load(.formatDescriptions)) ?? []).map { FourCC(CMFormatDescriptionGetMediaSubType($0)) }
                say("stream video track: \(Int(size.width))x\(Int(size.height)), \(String(format: "%.1f", rate / 1e6)) Mbit/s, codec \(codecs)")
            }
            let duration = (try? await avAsset.load(.duration)).map(CMTimeGetSeconds) ?? -1
            say("stream duration \(String(format: "%.1f", duration))s")
        }
    }

    /// End-to-end test of the real export code with a borrowed iCloud web session (cookies exported
    /// from icloudpd's session as JSON). Exports originals and smaller versions of a 1 GB+ video, a
    /// Live Photo and a plain photo, all iCloud-only, then reports route, size and speed per file.
    private func probeFastExport(video: PHAsset) async {
        guard let path = ProcessInfo.processInfo.environment["ORIGINALS_PROBE_COOKIES"],
              let data = FileManager.default.contents(atPath: path),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            say("no cookie file")
            return
        }
        let cookies: [HTTPCookie] = list.compactMap { c in
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c["name"] as? String ?? "", .value: c["value"] as? String ?? "",
                .domain: c["domain"] as? String ?? "", .path: c["path"] as? String ?? "/",
            ]
            if c["secure"] as? Bool == true { props[.secure] = "TRUE" }
            if let expires = c["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: expires) }
            return HTTPCookie(properties: props)
        }
        let signedIn = await ICloudWebSession.shared.useCookiesForTesting(cookies)
        say("signed in: \(signedIn) state: \(ICloudWebSession.shared.state)")
        guard signedIn else { return }

        let live = newestCloudOnly { $0.mediaType == .image && $0.mediaSubtypes.contains(.photoLive) }
        let photo = newestCloudOnly { $0.mediaType == .image && !$0.mediaSubtypes.contains(.photoLive) }
        let assets = [video, live, photo].compactMap { $0 }
        say("assets: \(assets.map { PHAssetResource.assetResources(for: $0).first?.originalFilename ?? "?" })")

        let exporter = ExportManager.shared
        exporter.maxConcurrent = 4
        let started = Date()
        exporter.export(assets, to: workDir.appendingPathComponent("originals"), variant: .original)
        exporter.export(assets, to: workDir.appendingPathComponent("smaller"), variant: .smaller)
        var lastReport = Date.distantPast
        while exporter.isBusy, Date().timeIntervalSince(started) < 900 {
            if Date().timeIntervalSince(lastReport) > 10 {
                lastReport = Date()
                let s = exporter.stats
                say("  \(s.finished)/\(s.total) files, \(s.completedBytes.byteString) of \(s.totalBytes.byteString)")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let elapsed = Date().timeIntervalSince(started)
        var bytes: Int64 = 0
        for item in exporter.items {
            let onDisk = item.outputURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }?.int64Value ?? -1
            bytes += max(0, onDisk)
            let photosSize = item.variant == .original ? (item.resource.byteCount ?? -1) : -1
            say("\(item.variant) \(item.filename): \(item.state) via \(item.route.map { "\($0)" } ?? "-") in \(String(format: "%.1f", item.elapsed ?? 0))s, disk \(onDisk) bytes, Photos size \(photosSize), match \(item.variant == .original ? String(onDisk == photosSize) : "n/a")\(item.routeNote.map { " NOTE: \($0)" } ?? "")")
        }
        say(String(format: "all done in %.1fs, %.1f MB written, %.2f MB/s overall", elapsed, Double(bytes) / 1e6, Double(bytes) / elapsed / 1e6))
    }

    /// Start an export signed out (Photos route), then sign in: the running file should restart
    /// on the iCloud route and finish there.
    private func probeSwitchRoute(video: PHAsset) async {
        let exporter = ExportManager.shared
        exporter.export([video], to: workDir.appendingPathComponent("switch"), variant: .original)
        try? await Task.sleep(for: .seconds(8))
        guard let item = exporter.items.first else { return }
        say("before sign-in: \(item.state) via \(item.route.map { "\($0)" } ?? "-"), downloadFraction \(item.downloadFraction)")
        guard let path = ProcessInfo.processInfo.environment["ORIGINALS_PROBE_COOKIES"],
              let data = FileManager.default.contents(atPath: path),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let cookies: [HTTPCookie] = list.compactMap { c in
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c["name"] as? String ?? "", .value: c["value"] as? String ?? "",
                .domain: c["domain"] as? String ?? "", .path: c["path"] as? String ?? "/",
            ]
            if c["secure"] as? Bool == true { props[.secure] = "TRUE" }
            if let expires = c["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: expires) }
            return HTTPCookie(properties: props)
        }
        let signedIn = await ICloudWebSession.shared.useCookiesForTesting(cookies)
        say("signed in: \(signedIn)")
        let t0 = Date()
        var lastState = ""
        while exporter.isBusy, Date().timeIntervalSince(t0) < 300 {
            let now = "\(item.state) via \(item.route.map { "\($0)" } ?? "-")"
            if now != lastState { say("  \(now)"); lastState = now }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let size = item.outputURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }?.int64Value ?? -1
        say("after: \(item.state) via \(item.route.map { "\($0)" } ?? "-") in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s after sign-in, size \(size) vs Photos \(item.resource.byteCount ?? -1)\(item.routeNote.map { " NOTE \($0)" } ?? "")")
    }

    /// Signed out, an iCloud-only file must wait (not crawl through Photos); after signing in, it must
    /// start on the direct route, and the sign-in must land in the Keychain.
    private func probePersist(video: PHAsset) async {
        let exporter = ExportManager.shared
        let icloud = ICloudWebSession.shared
        say("keychain cookies at start: \(ICloudCookieVault.load().count)")
        exporter.export([video], to: workDir.appendingPathComponent("persist"), variant: .original)
        guard let item = exporter.items.first else { return }
        try? await Task.sleep(for: .seconds(3))
        say("before sign-in check: state \(item.state), waiting \(exporter.isWaitingForSignIn(item)), route \(item.route.map { "\($0)" } ?? "-")")
        await icloud.refresh()
        say("after refresh: \(icloud.state), sheet requested \(icloud.isSignInPresented)")
        if icloud.account == nil {
            say("item while signed out: state \(item.state), waiting \(exporter.isWaitingForSignIn(item)), route \(item.route.map { "\($0)" } ?? "-")")
            // What the sign-in sheet does: open icloud.com in a web view, then pick up its cookies.
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            webView.customUserAgent = ICloudWebSession.userAgent
            webView.load(URLRequest(url: ICloudWebSession.homeURL))
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if await icloud.adoptWebKitCookies() { break }
            }
            say("after web view: \(icloud.state)")
        }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 30, item.bytesWritten < 50_000_000 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("item after sign-in: state \(item.state), route \(item.route.map { "\($0)" } ?? "-"), \(item.bytesWritten.byteString) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        exporter.cancelAll()
        try? await Task.sleep(for: .seconds(1))
        say("keychain cookies at end: \(ICloudCookieVault.load().count), auth \(ICloudCookieVault.load().contains { $0.name == "X-APPLE-WEBAUTH-TOKEN" })")
    }

    /// What smaller versions iCloud has for a video and a photo, how big their thumbnails are, and
    /// whether AVPlayer can stream a video version straight from its iCloud link.
    private func probeRenditions(video: PHAsset) async {
        let icloud = ICloudWebSession.shared
        await icloud.refresh()
        guard let account = icloud.account else { say("not signed in"); return }
        let client = ICloudPhotosClient(account: account, session: icloud.apiSession)
        let photo = newestCloudOnly { $0.mediaType == .image && !$0.mediaSubtypes.contains(.photoLive) }
        for asset in [video, photo].compactMap({ $0 }) {
            guard let name = ICloudPhotosClient.masterRecordName(for: asset) else { continue }
            let t0 = Date()
            guard let master = try? await client.lookup([name])[name] else { say("lookup failed"); continue }
            say("\(master.filename ?? "?") lookup \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            for (key, file) in master.files.sorted(by: { $0.value.size < $1.value.size }) {
                say("  \(key): \(file.size.byteString) \(file.fileType ?? "-")")
            }
            for key in ["resJPEGThumb", "resJPEGMed"] {
                guard let file = master.files[key] else { continue }
                let t1 = Date()
                if let (data, _) = try? await icloud.downloadSession.data(from: file.url),
                   let rep = NSBitmapImageRep(data: data) {
                    say("  \(key) image \(rep.pixelsWide)x\(rep.pixelsHigh) in \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
                }
            }
            for key in ["resVidMed", "resVidLarge"] {
                guard let file = master.files[key] else { continue }
                let t2 = Date()
                let item = AVPlayerItem(url: file.url)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.play()
                var ready = false
                while Date().timeIntervalSince(t2) < 20 {
                    if item.status == .failed { say("  \(key) failed: \(item.error?.localizedDescription ?? "?")"); break }
                    if item.status == .readyToPlay, player.currentTime().seconds > 0.5 { ready = true; break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                say("  \(key) playing: \(ready) after \(String(format: "%.2f", Date().timeIntervalSince(t2)))s, presentation \(item.presentationSize)")
                player.pause()
            }
        }
    }

    private func newestCloudOnly(_ match: @escaping (PHAsset) -> Bool) -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let all = PHAsset.fetchAssets(with: options)
        var found: PHAsset?
        all.enumerateObjects { asset, _, stop in
            guard match(asset) else { return }
            let resources = OriginalResources.resources(for: asset, options: .current)
            if !resources.isEmpty, resources.allSatisfy({ $0.isLocal == false }) {
                found = asset
                stop.pointee = true
            }
        }
        return found
    }

    /// Loads icloud.com in a web view configured like the sign-in sheet and saves a snapshot,
    /// to check Apple's sign-in page renders for this user agent.
    private func probeSignInPage() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        webView.customUserAgent = ICloudWebSession.userAgent
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        webView.load(URLRequest(url: ICloudWebSession.homeURL))
        try? await Task.sleep(for: .seconds(12))
        say("page title: \(webView.title ?? "nil"), url: \(webView.url?.absoluteString ?? "nil")")
        let image: UncheckedSendable<NSImage?> = await withCheckedContinuation { c in
            webView.takeSnapshot(with: nil) { image, _ in c.resume(returning: UncheckedSendable(image)) }
        }
        if let tiff = image.value?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: workDir.appendingPathComponent("signin.png"))
            say("snapshot saved")
        }
    }

    private func probeCloudID(_ asset: PHAsset) {
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        for (local, result) in mappings {
            switch result {
            case let .success(cloud): say("cloud identifier for \(local): \(cloud.stringValue)")
            case let .failure(error): say("cloud identifier failed: \(error)")
            }
        }
    }

    /// The smaller Photos-generated video, via the normal PhotoKit route. Measures how fast it arrives.
    private func probeDerivative(_ asset: PHAsset, quality: String) async {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = quality == "high" ? .highQualityFormat : (quality == "auto" ? .automatic : .mediumQualityFormat)
        DownloadIntent.edit.apply(to: options)
        say("--- requestAVAsset(version current, delivery \(quality))")
        let t0 = Date()
        var lastLogged = -1.0
        options.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async {
                if progress - lastLogged >= 0.05 || progress >= 1 {
                    lastLogged = progress
                    self.say(String(format: "  progress %.2f at %.1fs", progress, Date().timeIntervalSince(t0)))
                }
            }
        }
        let box = UncheckedSendable(Box())
        let requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
            DispatchQueue.main.async {
                box.value.done = true
                let seconds = Date().timeIntervalSince(t0)
                self.say("returned after \(String(format: "%.1f", seconds))s")
                self.describe(avAsset, info: info)
                if let url = (avAsset as? AVURLAsset)?.url, url.isFileURL,
                   let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
                    self.say("file \(size) bytes; \(String(format: "%.2f", Double(size) / seconds / 1e6)) MB/s")
                }
                box.value.asset = avAsset.map(UncheckedSendable.init)
            }
        }
        while !box.value.done, Date().timeIntervalSince(t0) < 300 { try? await Task.sleep(for: .milliseconds(250)) }
        if !box.value.done {
            PHImageManager.default().cancelImageRequest(requestID)
            say("no result within 300s; cancelled")
        }
        if let avAsset = box.value.asset?.value, let track = try? await avAsset.loadTracks(withMediaType: .video).first {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let rate = (try? await track.load(.estimatedDataRate)) ?? 0
            say("derivative video track: \(Int(size.width))x\(Int(size.height)), \(String(format: "%.1f", rate / 1e6)) Mbit/s")
        }
    }

    private func FourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    /// Largest iCloud-only video between 1 and 3 GB, skipping ones requested in earlier sessions.
    private func pickVideo() -> (PHAsset, PHAssetResource)? {
        let skip: Set<String> = ["IMG_5807.MOV", "IMG_5882.MOV"]
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let videos = PHAsset.fetchAssets(with: options)
        var best: (PHAsset, PHAssetResource, Int64)?
        videos.enumerateObjects { asset, _, _ in
            guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video }),
                  let size = resource.byteCount, size > 1_000_000_000, size < 3_000_000_000,
                  resource.isLocal == false, !skip.contains(resource.originalFilename) else { return }
            if best == nil || size > best!.2 { best = (asset, resource, size) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// .original + highQualityFormat: PhotoKit downloads the whole original first ("1Up Resources
    /// Download"). Let it run for `limit` seconds so the download rate can be measured, then quit.
    private func probePlayerItem(_ asset: PHAsset, limit: TimeInterval) async {
        say("--- requestPlayerItem(.original), \(Int(limit))s")
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        options.deliveryMode = .highQualityFormat
        DownloadIntent.oneUp.apply(to: options)
        let t0 = Date()
        var lastLogged = -1.0
        options.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async {
                if progress - lastLogged >= 0.002 {
                    lastLogged = progress
                    self.say(String(format: "  progress %.4f at %.1fs", progress, Date().timeIntervalSince(t0)))
                }
            }
        }
        let requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
            DispatchQueue.main.async {
                self.say("returned after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                self.describe(item?.asset, info: info)
            }
        }
        try? await Task.sleep(for: .seconds(limit))
        PHImageManager.default().cancelImageRequest(requestID)
        say("cancelled after \(Int(limit))s")
    }

    private func probeAVAsset(_ asset: PHAsset) async {
        say("--- requestAVAsset(.original), 40s limit")
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        options.deliveryMode = .highQualityFormat
        DownloadIntent.oneUp.apply(to: options)
        let t0 = Date()
        var lastLogged = -1.0
        options.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async {
                if progress - lastLogged >= 0.01 || progress >= 1 {
                    lastLogged = progress
                    self.say(String(format: "  progress %.3f at %.1fs", progress, Date().timeIntervalSince(t0)))
                }
            }
        }
        let box = UncheckedSendable(Box())
        let requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
            DispatchQueue.main.async {
                box.value.done = true
                self.say("returned after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                self.describe(avAsset, info: info)
            }
        }
        while !box.value.done, Date().timeIntervalSince(t0) < 40 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !box.value.done {
            PHImageManager.default().cancelImageRequest(requestID)
            say("no result within 40s; cancelled")
        }
    }

    private final class Box {
        var done = false
        var asset: UncheckedSendable<AVAsset>?
    }

    private func describe(_ avAsset: AVAsset?, info: [AnyHashable: Any]?) {
        guard let avAsset else {
            say("asset: nil")
            say("info: \(String(describing: info))")
            return
        }
        say("asset type: \(type(of: avAsset))")
        if let urlAsset = avAsset as? AVURLAsset {
            say("url: \(urlAsset.url.absoluteString)")
            say("scheme: \(urlAsset.url.scheme ?? "nil"), resourceLoader delegate: \(urlAsset.resourceLoader.delegate.map { String(describing: type(of: $0)) } ?? "none")")
        }
        say("info: \(String(describing: info))")
    }
}
#endif
