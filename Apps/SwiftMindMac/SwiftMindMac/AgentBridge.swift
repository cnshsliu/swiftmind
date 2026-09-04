import AppKit
import Foundation
import SwiftMindCore

/// Local agent bridge: a Unix-domain-socket server inside the app container.
/// The `swiftmind mcp` CLI process connects here; agents talk MCP over stdio
/// to the CLI. No network, no new entitlements.
/// Spec: docs/superpowers/specs/2026-09-03-agent-live-bridge-design.md
@MainActor
final class AgentBridge {
    /// Release bundle id — the CLI derives the default container path from
    /// this constant (keep in sync with `BridgeClient` in the CLI target).
    /// Debug builds use `app.swiftmind.mac.dev`, so their bridge lives in a
    /// separate container and never fights the permanent Release install;
    /// the bridge directory itself is resolved from this app's own sandbox
    /// container at runtime (see `bridgeDirectory()`).
    nonisolated static let bundleID = "app.swiftmind.mac"
    nonisolated static let socketName = "agent.sock"
    nonisolated static let tokenName = "agent.token"
    nonisolated static let maxFrameBytes: UInt32 = 4 * 1024 * 1024

    private let ioQueue = DispatchQueue(label: "app.swiftmind.mac.agent-bridge")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var token = ""
    private var stopped = false
    private weak var appModel: AppModel?

    /// Container-side bridge directory (app view; sandbox-resolved to
    /// ~/Library/Containers/<bundleID>/Data/Library/SwiftMind).
    private static func bridgeDirectory() -> URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMind", isDirectory: true)
    }

    func start(appModel: AppModel) {
        guard acceptSource == nil else { return }
        stopped = false
        // Kill switch: `defaults write app.swiftmind.mac swiftmind.agentBridge -bool false`
        // (Debug builds: use the app.swiftmind.mac.dev domain instead)
        if let disabled = UserDefaults.standard.object(forKey: "swiftmind.agentBridge") as? Bool,
           !disabled {
            return
        }
        self.appModel = appModel
        token = UUID().uuidString

        let dir = Self.bridgeDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            chmod(dir.path, 0o700)
            let tokenURL = dir.appendingPathComponent(Self.tokenName)
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
            chmod(tokenURL.path, 0o600)
        } catch {
            NSLog("AgentBridge: cannot prepare %@ — bridge disabled", dir.path)
            return
        }

        let socketPath = dir.appendingPathComponent(Self.socketName).path
        unlink(socketPath)  // stale socket from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            NSLog("AgentBridge: socket() failed — bridge disabled")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("AgentBridge: socket path too long — bridge disabled")
            close(listenFD)
            listenFD = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, addrLen)
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else {
            NSLog("AgentBridge: bind/listen failed on %@ — bridge disabled", socketPath)
            close(listenFD)
            listenFD = -1
            return
        }
        chmod(socketPath, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: ioQueue)
        source.setEventHandler { [weak self, listenFD] in
            self?.acceptOne(listenFD)
        }
        source.setCancelHandler { [listenFD] in
            close(listenFD)
        }
        acceptSource = source
        source.resume()
        NSLog("AgentBridge: listening on %@", socketPath)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        stopped = true
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        let dir = Self.bridgeDirectory()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.socketName))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.tokenName))
    }

    // MARK: - Connection handling (ioQueue, nonisolated)

    /// One request per connection; the CLI opens a fresh connection per call.
    private nonisolated func acceptOne(_ listenFD: Int32) {
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }
        // Darwin raises SIGPIPE on send() to a closed peer — that would kill
        // the app. Belt and braces: SO_NOSIGPIPE on the fd (accepted on
        // AF_UNIX here, kept for defense in depth) and MSG_NOSIGNAL on every
        // send, which is the operative guard — EPIPE becomes a plain send()
        // error.
        var yes: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Bound the blocking recv/send so a client dribbling a partial frame
        // or stalling mid-response can't block the serial ioQueue forever.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let requestData = Self.readFrame(conn) else { return }
        let response: [String: Any] = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.handle(requestData)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            Self.writeFrame(conn, data)
        }
    }

    nonisolated private static func readFrame(_ fd: Int32) -> Data? {
        guard let header = readFully(fd, count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= maxFrameBytes else { return nil }
        return readFully(fd, count: Int(length))
    }

    nonisolated private static func readFully(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while data.count < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, min(ptr.count, count - data.count), 0)
            }
            guard n > 0 else {
                if n < 0, errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    nonisolated private static func writeFrame(_ fd: Int32, _ data: Data) {
        var length = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        guard sendAll(fd, header), sendAll(fd, data) else { return }
    }

    /// Loop over short writes; EINTR retries, EPIPE/any other error silently
    /// drops the response (MSG_NOSIGNAL keeps EPIPE from killing the app).
    nonisolated private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { ptr in
            guard var base = ptr.baseAddress else { return true }
            var remaining = ptr.count
            while remaining > 0 {
                let n = send(fd, base, remaining, MSG_NOSIGNAL)
                if n > 0 {
                    base += n
                    remaining -= n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Method dispatch (main actor)

    private func handle(_ requestData: Data) -> [String: Any] {
        let id: Any = (try? JSONSerialization.jsonObject(with: requestData))
            .flatMap { ($0 as? [String: Any])?["id"] } ?? NSNull()
        func failure(_ code: String, _ message: String) -> [String: Any] {
            ["id": id, "ok": false, "error": ["code": code, "message": message]]
        }
        guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let method = request["method"] as? String else {
            return failure("usage", "malformed request")
        }
        guard (request["token"] as? String) == token else {
            return failure("unauthorized", "missing or wrong token")
        }
        // In-flight connections accepted before termination must not ack
        // edits whose autosave will never land.
        guard !stopped else {
            return failure("no_session", "bridge is shutting down")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        do {
            let result = try execute(method: method, params: params)
            return ["id": id, "ok": true, "result": result]
        } catch let error as BridgeFailure {
            return failure(error.code, error.message)
        } catch let error as BatchOpError {
            return ["id": id, "ok": false, "error": [
                "code": "op_error", "message": error.message,
                "opIndex": error.opIndex, "op": error.opName,
            ]]
        } catch {
            return failure("op_error", String(describing: error))
        }
    }

    private struct BridgeFailure: Error {
        let code: String
        let message: String
    }

    private func execute(method: String, params: [String: Any]) throws -> [String: Any] {
        guard let appModel else {
            throw BridgeFailure(code: "no_session", message: "app is shutting down")
        }
        let session = appModel.session
        switch method {
        case "read":
            return AgentProtocol.mapJSON(
                for: session.store.map,
                formulaResults: session.store.formulaResults()
            )
        case "find":
            guard let query = params["query"] as? String else {
                throw BridgeFailure(code: "usage", message: "find requires query")
            }
            let hits = MapSearch.search(map: session.store.map, query: query)
            return ["hits": hits.map {
                ["id": $0.nodeID.rawValue, "title": $0.title, "matchInNote": $0.matchInNote]
            }]
        case "applyOps":
            guard !session.isBrainMode else {
                throw BridgeFailure(code: "no_session", message: "brain navigator has no editable map")
            }
            guard let opsValue = params["ops"],
                  let opsData = try? JSONSerialization.data(withJSONObject: opsValue) else {
                throw BridgeFailure(code: "usage", message: "applyOps requires ops array")
            }
            let ops: [MapOp]
            do {
                ops = try JSONDecoder().decode([MapOp].self, from: opsData)
            } catch {
                throw BridgeFailure(code: "usage", message: "invalid ops JSON: \(error.localizedDescription)")
            }
            guard !ops.isEmpty else {
                throw BridgeFailure(code: "usage", message: "ops array is empty")
            }
            let command = CompositeAgentCommand(ops: ops)
            try session.applyThrowing(command)
            session.showToast("Agent edit (\(ops.count) ops) · ⌘Z to undo", kind: .success)
            return ["affected": command.affected.map(\.rawValue)]
        case "session":
            return [
                "mapPath": appModel.currentMapURL?.path as Any,
                "title": session.store.map.title,
                "selectedIds": session.store.selection.selectedIDs.map(\.rawValue),
                "canUndo": session.canUndo,
                "canRedo": session.canRedo,
                "isBrainMode": session.isBrainMode,
            ]
        case "new":
            let title = params["title"] as? String ?? "Untitled"
            guard let url = appModel.createAndOpenMap(titled: title) else {
                throw BridgeFailure(code: "file_error", message: "could not create map")
            }
            return ["path": url.path]
        default:
            throw BridgeFailure(code: "usage", message: "unknown method: \(method)")
        }
    }
}
