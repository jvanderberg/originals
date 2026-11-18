import AVKit
import Photos
import SwiftUI

/// Large preview of one item. ← → move through the current view, Space or Esc closes.
/// Signed in to iCloud, items not on this Mac are shown from iCloud's own smaller versions (a 1080p
/// video, a ~2,048 px JPEG), fetched directly; otherwise from Photos' preview versions.
struct PreviewView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ExportManager.self) private var exporter
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loadProgress: Double?
    @State private var loadingNote: String?
    @State private var resources: [ResourceInfo] = []
    @State private var imageRequest: PHImageRequestID?
    @FocusState private var focused: Bool

    init(startIndex: Int) {
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.black
                if let player {
                    PlayerView(player: player)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let loadProgress {
                    ProgressView(value: loadProgress) {
                        Text("Loading preview through Photos…")
                    }
                    .frame(width: 220)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 12)
                } else if let loadingNote {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(loadingNote)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 12)
                }
            }
            infoBar
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 600, idealHeight: 820)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.space) { dismiss(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onAppear { focused = true }
        .onDisappear {
            player?.pause()
            if let imageRequest { PHImageManager.default().cancelImageRequest(imageRequest) }
        }
        .task(id: index) { await load() }
    }

    private var asset: PHAsset? { library.asset(at: index) }

    private var infoBar: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let asset {
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "No date")
                        .font(.headline)
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight)\(asset.mediaType == .video ? " · \(clockString(asset.duration))" : "")")
                        .foregroundStyle(.secondary)
                }
                Text("\(index + 1) of \(library.count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(resources) { r in
                    HStack(spacing: 6) {
                        Image(systemName: r.isLocal == false ? "icloud" : "internaldrive")
                            .foregroundStyle(.secondary)
                            .help(r.isLocal == false ? "Original is only in iCloud" : "Original is on this Mac")
                        Text(r.filename).fontWeight(.medium)
                        Text(r.kind).foregroundStyle(.secondary)
                        if let bytes = r.bytes { Text(bytes.byteString).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
            Spacer()
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= library.count - 1)
                Button("Export Original…") {
                    if let asset { ExportPanel.export([asset], exporter: exporter) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.bar)
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < library.count else { return }
        index = next
    }

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        loadProgress = nil
        loadingNote = nil
        if let imageRequest { PHImageManager.default().cancelImageRequest(imageRequest) }
        guard let asset else { return }
        let assetResources = OriginalResources.resources(for: asset, options: .current)
        resources = assetResources.map(ResourceInfo.init)
        let current = index
        let primary = assetResources.first { $0.type == .video || $0.type == .photo }
        let direct = ICloudWebSession.shared.account != nil && primary?.isLocal != true

        if direct, await loadFromICloud(asset, current: current) { return }
        guard !Task.isCancelled, index == current else { return }

        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            DownloadIntent.oneUp.apply(to: options)
            options.deliveryMode = .automatic
            options.progressHandler = { progress, _, _, _ in
                DispatchQueue.main.async { if index == current { loadProgress = progress < 1 ? progress : nil } }
            }
            let box: UncheckedSendable<AVPlayerItem?> = await withCheckedContinuation { continuation in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                    continuation.resume(returning: UncheckedSendable(item))
                }
            }
            guard !Task.isCancelled, index == current, let item = box.value else { return }
            loadProgress = nil
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
        } else {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            DownloadIntent.oneUp.apply(to: options)
            options.progressHandler = { progress, _, _, _ in
                DispatchQueue.main.async { if index == current { loadProgress = progress < 1 ? progress : nil } }
            }
            let target = CGSize(width: 2800, height: 2800)
            imageRequest = PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { result, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let update = {
                    guard index == current else { return }
                    if let result { image = result }
                    if !degraded { loadProgress = nil }
                }
                if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
            }
        }
    }
}

extension PreviewView {
    /// Plays iCloud's 1080p (or smaller) version of a video, or shows its ~2,048 px JPEG of a photo.
    /// Returns false if iCloud doesn't have one, so the caller can fall back to Photos.
    fileprivate func loadFromICloud(_ asset: PHAsset, current: Int) async -> Bool {
        loadingNote = "Loading from iCloud…"
        defer { if index == current { loadingNote = nil } }

        if asset.mediaType == .video {
            guard let master = try? await ICloudMasters.shared.master(for: asset),
                  let file = ["resVidLarge", "resVidMed", "resVidSmall"].lazy.compactMap({ master.files[$0] }).first,
                  !Task.isCancelled, index == current else { return false }
            let item = AVPlayerItem(url: file.url)
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
            // Keep the loading note up until it starts; give up on iCloud if it can't play it.
            let start = Date()
            while item.status == .unknown, Date().timeIntervalSince(start) < 15, !Task.isCancelled, index == current {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if item.status == .failed, index == current {
                player.pause()
                self.player = nil
                return false
            }
            return true
        }

        guard let image = await ICloudThumbnails.shared.image(for: asset, pixelSide: 2048, size: .medium),
              !Task.isCancelled, index == current else { return false }
        self.image = image
        return true
    }
}

private struct ResourceInfo: Identifiable {
    let id = UUID()
    let filename: String
    let kind: String
    let bytes: Int64?
    let isLocal: Bool?

    init(_ resource: PHAssetResource) {
        filename = resource.originalFilename
        kind = OriginalResources.label(for: resource.type)
        bytes = resource.byteCount
        isLocal = resource.isLocal
    }
}

/// AppKit's player view. SwiftUI's VideoPlayer aborts while loading on this SDK/OS combination.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
