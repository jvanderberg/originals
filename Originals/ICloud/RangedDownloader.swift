import Foundation

/// Downloads one file as parallel byte ranges, each written straight to its place in the file.
/// On this Mac and connection: 27.5 MB/s on one connection, 31.8 MB/s with 8, versus ~0.7 MB/s
/// through Photos.
struct RangedDownloader: Sendable {
    let session: URLSession
    var chunkSize: Int64 = 8 << 20
    var connections = 6

    enum Failure: LocalizedError {
        case status(Int)
        case shortRange(expected: Int, got: Int)
        case wrongSize(expected: Int64, got: Int64)
        case io(Int32)

        var errorDescription: String? {
            switch self {
            case let .status(code): "Download returned HTTP \(code)"
            case let .shortRange(expected, got): "Got \(got) bytes of a \(expected)-byte range"
            case let .wrongSize(expected, got): "File is \(got) bytes, expected \(expected)"
            case let .io(code): "Couldn't write the file (\(String(cString: strerror(code))))"
            }
        }
    }

    /// `progress` gets the running byte total, from any thread.
    func download(_ url: URL, size: Int64, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Failure.io(errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw Failure.io(errno) }

        let counter = Counter()
        let ranges = stride(from: Int64(0), to: max(size, 1), by: Int(chunkSize)).map { start in
            (start, min(start + chunkSize, size) - 1)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(connections, ranges.count) {
                let range = ranges[next]
                group.addTask { try await fetch(url, range: range, fd: fd, counter: counter, progress: progress) }
                next += 1
            }
            while try await group.next() != nil {
                if next < ranges.count {
                    let range = ranges[next]
                    group.addTask { try await fetch(url, range: range, fd: fd, counter: counter, progress: progress) }
                    next += 1
                }
            }
        }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io(errno) }
        guard info.st_size == size, counter.total == size else {
            throw Failure.wrongSize(expected: size, got: counter.total)
        }
    }

    private func fetch(_ url: URL, range: (Int64, Int64), fd: Int32, counter: Counter,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        let (start, end) = range
        let length = Int(end - start + 1)
        var lastError: Error = Failure.status(0)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 206 || (status == 200 && start == 0 && data.count == length) else {
                    throw Failure.status(status)
                }
                guard data.count == length else { throw Failure.shortRange(expected: length, got: data.count) }
                try data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let n = pwrite(fd, buffer.baseAddress! + offset, buffer.count - offset, off_t(start) + off_t(offset))
                        if n < 0 { throw Failure.io(errno) }
                        offset += n
                    }
                }
                progress(counter.add(Int64(length)))
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
        throw lastError
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        func add(_ n: Int64) -> Int64 { lock.withLock { bytes += n; return bytes } }
        var total: Int64 { lock.withLock { bytes } }
    }
}
