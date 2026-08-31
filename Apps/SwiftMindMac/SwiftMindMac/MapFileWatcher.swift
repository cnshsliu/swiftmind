import Foundation

/// Watches a file's parent directory for external modifications.
/// Atomic saves (temp + rename) replace the inode, so the file itself
/// cannot be watched reliably — the directory is.
final class MapFileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private(set) var watchedPath: String?
    var onChange: (() -> Void)?

    func watch(url: URL) {
        stop()
        let dir = url.deletingLastPathComponent().path
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedPath = url.path
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.onChange?()
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
        watchedPath = nil
    }

    deinit { stop() }
}
