import AppKit
import Photos

/// Root view of a cell. Claims every click inside it so the collection view handles selection,
/// instead of the badge labels swallowing clicks.
private final class CellView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
}

final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCell")

    private let imageLayer = CALayer()
    private let selectionLayer = CALayer()
    private let durationLabel = NSTextField(labelWithString: "")
    private let cloudIcon = NSImageView()
    private let liveIcon = NSImageView()
    private let checkIcon = NSImageView()
    private var assetID: String?
    private var showsBadges = true
    private var upgradeWork: DispatchWorkItem?
    private var shownPixelSide: CGFloat = 0
    private var requestID: PHImageRequestID?
    private var iCloudTask: Task<Void, Never>?
    private weak var imageManager: PHImageManager?

    override func loadView() {
        let root = CellView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.15).cgColor

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        // No implicit cross-fades: a fade from the previous asset's image leaves a double exposure.
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.layer?.addSublayer(imageLayer)

        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        root.layer?.addSublayer(selectionLayer)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.shadow = shadow

        let white = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        cloudIcon.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "Original is in iCloud")?
            .withSymbolConfiguration(white)
        cloudIcon.shadow = shadow
        cloudIcon.toolTip = "The original is only in iCloud and will be downloaded on export"
        liveIcon.image = NSImage(systemSymbolName: "livephoto", accessibilityDescription: "Live Photo")?
            .withSymbolConfiguration(white)
        liveIcon.shadow = shadow
        checkIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold).applying(.init(paletteColors: [.white, .controlAccentColor])))
        checkIcon.shadow = shadow

        for view in [durationLabel, cloudIcon, liveIcon, checkIcon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            durationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            cloudIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            cloudIcon.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            liveIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            liveIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
            checkIcon.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -5),
            checkIcon.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
        ])
        view = root
        updateSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds
        selectionLayer.frame = view.bounds
        CATransaction.commit()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        let selected = (isSelected && highlightState != .forDeselection) || highlightState == .forSelection
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.borderWidth = selected ? 3 : 0
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        CATransaction.commit()
        checkIcon.isHidden = !selected
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelRequest()
        imageLayer.contents = nil
        shownPixelSide = 0
        assetID = nil
        cloudIcon.isHidden = true
    }

    private func cancelRequest() {
        upgradeWork?.cancel()
        upgradeWork = nil
        iCloudTask?.cancel()
        iCloudTask = nil
        if let requestID { imageManager?.cancelImageRequest(requestID) }
        requestID = nil
    }

    func configure(asset: PHAsset, pixelSide: CGFloat, imageManager: PHImageManager, localStatus: LocalStatusCache) {
        cancelRequest()
        let id = asset.localIdentifier
        if assetID != id {
            imageLayer.contents = nil
            shownPixelSide = 0
        }
        assetID = id
        self.imageManager = imageManager

        // Badges crowd small thumbnails, so drop them below a readable size.
        let pointSide = view.bounds.width > 0 ? view.bounds.width : pixelSide / 2
        showsBadges = pointSide >= 84
        durationLabel.stringValue = asset.mediaType == .video && showsBadges ? clockString(asset.duration) : ""
        liveIcon.isHidden = !showsBadges || !asset.mediaSubtypes.contains(.photoLive)

        requestThumbnail(asset: asset, pixelSide: pixelSide, allowNetwork: false)
        refreshStatus(asset: asset, localStatus: localStatus)
    }

    /// Local thumbnail first. A moment later, if the cell still shows the same asset and what we have
    /// is smaller than the cell needs, fetch a sharper one (from iCloud if necessary). The delay keeps
    /// cells that just scroll past from flooding photolibraryd with preview downloads.
    private func requestThumbnail(asset: PHAsset, pixelSide: CGFloat, allowNetwork: Bool) {
        let id = asset.localIdentifier
        let options = PHImageRequestOptions()
        options.deliveryMode = allowNetwork ? .highQualityFormat : .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        if allowNetwork { DownloadIntent.grid.apply(to: options) }
        let target = CGSize(width: pixelSide, height: pixelSide)
        requestID = imageManager?.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { [weak self] image, _ in
            let apply = {
                guard let self, let image else { return }
                self.show(image, for: id)
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        if !allowNetwork {
            // Signed in to iCloud, sharper versions come straight from iCloud (fast, and cached on
            // disk); otherwise from Photos, which is slow for anything it has to download.
            let direct = ICloudWebSession.shared.account != nil
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.assetID == id, self.shownPixelSide < pixelSide * 0.7 else { return }
                if direct {
                    self.iCloudTask = Task { [weak self] in
                        let image = await ICloudThumbnails.shared.image(for: asset, pixelSide: pixelSide)
                        guard let self, !Task.isCancelled else { return }
                        if let image {
                            self.show(image, for: id)
                        } else if self.assetID == id {
                            self.requestThumbnail(asset: asset, pixelSide: pixelSide, allowNetwork: true)
                        }
                    }
                } else {
                    self.requestThumbnail(asset: asset, pixelSide: pixelSide, allowNetwork: true)
                }
            }
            upgradeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (direct ? 0.15 : 0.4), execute: work)
        }
    }

    private func show(_ image: NSImage, for id: String) {
        guard assetID == id else { return }
        let side = Self.pixelSide(of: image)
        // Never replace a sharper image with a blurrier one.
        guard side >= shownPixelSide else { return }
        shownPixelSide = side
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    /// The shorter pixel dimension, which is what has to cover the square cell under aspect-fill.
    private static func pixelSide(of image: NSImage) -> CGFloat {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGFloat(min(rep.pixelsWide, rep.pixelsHigh))
        }
        return min(image.size.width, image.size.height)
    }

    func refreshStatus(asset: PHAsset, localStatus: LocalStatusCache) {
        let id = asset.localIdentifier
        cloudIcon.isHidden = true
        localStatus.state(for: asset) { [weak self] state in
            guard let self, self.assetID == id else { return }
            self.cloudIcon.isHidden = state != .cloud || !self.showsBadges
        }
    }
}
