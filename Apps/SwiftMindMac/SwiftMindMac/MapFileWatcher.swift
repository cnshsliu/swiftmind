import Foundation

/// Watches a file's parent directory for external modifications.
/// Atomic saves (temp + rename) replace the inode, so the file itself
/// cannot be watched reliably — the directory is.
@MainActor
final class MapFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    var onChange: (() -> Void)?

    func watch(url: URL) {
        stop()
        let dir = url.deletingLastPathComponent().path
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Handler runs on the main queue, so main-actor access is safe.
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    deinit {
        // deinit is nonisolated; DispatchSource cancellation is thread-safe.
        source?.cancel()
    }
}
