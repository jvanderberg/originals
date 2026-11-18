import Photos
import SwiftUI

enum QueueFilter: String, CaseIterable, Identifiable {
    case all = "All", inProgress = "In Progress", failed = "Failed", done = "Done"
    var id: Self { self }

    @MainActor
    func includes(_ item: ExportItem) -> Bool {
        switch (self, item.state) {
        case (.all, _): true
        case (.inProgress, .active), (.inProgress, .queued): true
        case (.failed, .failed), (.failed, .cancelled): true
        case (.done, .done), (.done, .skipped): true
        default: false
        }
    }
}

struct ExportQueueView: View {
    @Environment(ExportManager.self) private var exporter
    @State private var filter: QueueFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            if exporter.items.isEmpty {
                ContentUnavailableView(
                    "No Exports",
                    systemImage: "tray.and.arrow.down",
                    description: Text("Select items and press ⌘E to export their unmodified originals. Progress for every file shows up here.")
                )
            } else {
                ExportSummaryView()
                    .padding(12)
                FastDownloadHint()
                Divider()
                Picker("Show", selection: $filter) {
                    ForEach(QueueFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                List(rows) { item in
                    ExportRow(item: item)
                }
                .listStyle(.inset)
            }
        }
    }

    /// Running items first so they're visible without scrolling, then the rest in queue order.
    private var rows: [ExportItem] {
        let matching = exporter.items.filter { filter.includes($0) }
        return matching.filter { $0.state == .active } + matching.filter { $0.state != .active }
    }
}

private struct ExportSummaryView: View {
    @Environment(ExportManager.self) private var exporter

    var body: some View {
        @Bindable var exporter = exporter
        let s = exporter.stats
        let busy = s.active + s.queued > 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title(s, busy: busy)).font(.headline)
                Spacer()
                if let folder = exporter.lastDestination {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                    }
                    .buttonStyle(.link)
                    .help(folder.path)
                }
            }
            ProgressView(value: s.fraction)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                StatsGrid(stats: s, busy: busy, now: context.date)
            }
            if s.failed > 0 {
                Label("\(s.failed) failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                if busy {
                    Button(exporter.isPaused ? "Resume" : "Pause") { exporter.isPaused.toggle() }
                    Button("Cancel All", role: .destructive) { exporter.cancelAll() }
                }
                if s.failed > 0 {
                    Button("Retry Failed") { exporter.retryFailed() }
                }
                Spacer()
                Button("Clear Finished") { exporter.clearFinished() }
                    .disabled(s.finished + s.cancelled == 0)
            }
            .controlSize(.small)
            Stepper("Parallel downloads: \(exporter.maxConcurrent)", value: $exporter.maxConcurrent, in: 1...12)
                .controlSize(.small)
                .help("How many originals to download from iCloud at the same time")
        }
        .font(.callout)
    }

    private func title(_ s: ExportStats, busy: Bool) -> String {
        if busy { return exporter.isPaused ? "Paused" : "Exporting" }
        return s.failed > 0 ? "Finished with errors" : "Export complete"
    }
}

/// Fixed two-column grid of labelled stats. Every cell is one line, and the rows are the same
/// whether the export is running, paused, or finished; only the values change.
private struct StatsGrid: View {
    @Environment(ExportManager.self) private var exporter
    let stats: ExportStats
    let busy: Bool
    let now: Date

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                StatCell(label: "Files", value: "\(stats.finished.formatted()) of \(stats.total.formatted())")
                StatCell(label: "Data", value: "\(stats.completedBytes.byteString) of \(stats.totalBytes.byteString)")
            }
            GridRow {
                StatCell(label: "Speed", value: speed)
                StatCell(label: busy ? "Time left" : "Took", value: busy ? timeLeft : took)
            }
            GridRow {
                StatCell(label: "Downloading", value: busy ? "\(stats.active) now, \(stats.queued) waiting" : "—")
                StatCell(label: "Elapsed", value: elapsed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rate: Double? {
        guard busy, !exporter.isPaused else { return nil }
        return exporter.bytesPerSecond
    }

    private var speed: String {
        if !busy { return "—" }
        if exporter.isPaused { return "Paused" }
        guard let rate else { return "Measuring…" }
        return "\(Int64(rate).byteString)/s"
    }

    private var timeLeft: String {
        guard let rate, rate > 1024 else { return "—" }
        return "about \(durationString(Double(stats.remainingBytes) / rate))"
    }

    private var took: String {
        guard let start = exporter.batchStartedAt, let end = exporter.batchFinishedAt else { return "—" }
        return durationString(end.timeIntervalSince(start))
    }

    private var elapsed: String {
        guard let start = exporter.batchStartedAt else { return "—" }
        return clockString((exporter.batchFinishedAt ?? now).timeIntervalSince(start))
    }
}

private struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExportRow: View {
    @Environment(ExportManager.self) private var exporter
    let item: ExportItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AssetThumbnail(asset: item.asset, side: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if item.expectedBytes > 0 {
                        Text(item.expectedBytes.byteString)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                status
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued:
            if exporter.isWaitingForSignIn(item) {
                Label("Waiting for iCloud sign-in", systemImage: "person.badge.key.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(item.wasLocal == false ? "Waiting · \(item.kind) · in iCloud" : "Waiting · \(item.kind)")
                    .foregroundStyle(.secondary)
            }
        case .active:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    if item.progress > 0 {
                        ProgressView(value: item.progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    // Fixed columns: what's happening on the left, amount in the middle, time on the right.
                    HStack(spacing: 8) {
                        Text(phase)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(amount)
                            .lineLimit(1)
                            .fixedSize()
                        Text(item.startedAt.map { clockString(context.date.timeIntervalSince($0)) } ?? "")
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    if let note = item.retryNote {
                        Text(note)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    routeNote
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Label("Saved\(item.elapsed.map { " in \(durationString($0))" } ?? "")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer(minLength: 4)
                    if let route = item.route {
                        Text(route == .iCloud ? "iCloud direct" : "via Photos")
                            .foregroundStyle(.secondary)
                    }
                }
                routeNote
            }
        case .skipped:
            Label("Already in folder", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 3) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Button("Retry") { exporter.retry(item) }
                    .controlSize(.small)
            }
        case .cancelled:
            HStack {
                Text("Cancelled").foregroundStyle(.secondary)
                Button("Retry") { exporter.retry(item) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var routeNote: some View {
        if let note = item.routeNote {
            Text(note)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var phase: String {
        if item.route == .iCloud {
            return item.bytesWritten > 0 ? "iCloud direct" : "Finding in iCloud"
        }
        if item.bytesWritten > 0 { return "Saving" }
        if item.downloadFraction > 0 { return "Via Photos (slow)" }
        return item.wasLocal == true ? "Reading from library" : "Waiting on Photos"
    }

    /// The file's size is already at the top right, so just how far along it is.
    private var amount: String {
        item.progress > 0 ? "\(Int(item.progress * 100))%" : ""
    }

    @ViewBuilder
    private var menu: some View {
        if let url = item.outputURL {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        switch item.state {
        case .queued, .active:
            Button("Cancel") { exporter.cancel(item) }
        case .failed, .cancelled:
            Button("Retry") { exporter.retry(item) }
        default:
            EmptyView()
        }
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            let size = CGSize(width: side * 2, height: side * 2)
            let box: UncheckedSendable<NSImage?> = await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { result, _ in
                    continuation.resume(returning: UncheckedSendable(result))
                }
            }
            image = box.value
        }
    }
}

/// Files that have to come from iCloud wait for an iCloud sign-in; say so, and offer both ways on.
/// If the person chose Photos for some, a smaller note says why they're slow.
private struct FastDownloadHint: View {
    @Environment(ExportManager.self) private var exporter
    @Environment(ICloudWebSession.self) private var icloud

    var body: some View {
        let waiting = exporter.waitingForSignIn.count
        if waiting > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("\(waiting) file\(waiting == 1 ? " is" : "s are") waiting for you to sign in to iCloud")
                        .font(.headline)
                } icon: {
                    Image(systemName: "person.badge.key.fill").foregroundStyle(.orange)
                }
                Text(icloud.state == .checking
                     ? "Checking your saved iCloud sign-in…"
                     : "Signed in, files download straight from iCloud at full speed. Through Photos they download at about 0.7 MB/s.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sign In to iCloud…") { icloud.isSignInPresented = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(icloud.state == .checking)
                    Button("Use Photos (slow)") { exporter.downloadWaitingThroughPhotos() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        } else if icloud.account == nil, exporter.items.contains(where: needsICloud) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tortoise.fill")
                    .foregroundStyle(.orange)
                Text("Photos limits iCloud downloads to about 0.7 MB/s. Sign in to iCloud to download directly.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Sign In…") { icloud.isSignInPresented = true }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func needsICloud(_ item: ExportItem) -> Bool {
        guard item.state == .queued || item.state == .active else { return false }
        return item.variant == .smaller || item.wasLocal != true
    }
}
