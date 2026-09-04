import Foundation

/// Client side of the app's AgentBridge Unix socket.
/// Keep paths in sync with `AgentBridge` in the app target.
enum BridgeClient {
    enum Failure: Error, CustomStringConvertible {
        case appNotRunning
        case unresponsive
        case badResponse(String)

        var description: String {
            switch self {
            case .appNotRunning:
                return "SwiftMind.app is not running (start it, or use the file-mode CLI)"
            case .unresponsive:
                return "SwiftMind.app is not responding (bridge timed out or dropped the connection)"
            case .badResponse(let detail):
                return "bad bridge response: \(detail)"
            }
        }
    }

    /// Testing hook: SWIFTMIND_BRIDGE_DIR overrides the container path.
    private static var bridgeDirectory: String {
        ProcessInfo.processInfo.environment["SWIFTMIND_BRIDGE_DIR"]
            ?? NSHomeDirectory()
                + "/Library/Containers/app.swiftmind.mac/Data/Library/SwiftMind"
    }

    /// One request, one short-lived connection.
    static func call(method: String, params: [String: Any]) throws -> [String: Any] {
        let tokenURL = URL(fileURLWithPath: bridgeDirectory + "/agent.token")
        guard let tokenData = try? Data(contentsOf: tokenURL),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw Failure.appNotRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.appNotRunning }
        defer { close(fd) }

        let socketPath = bridgeDirectory + "/agent.sock"
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure.badResponse("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    dest.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Failure.appNotRunning }

        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let request: [String: Any] = [
            "id": 1, "token": token, "method": method, "params": params,
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request) else {
            throw Failure.badResponse("request not encodable")
        }
        // MSG_NOSIGNAL is mandatory on macOS AF_UNIX sends: without it a
        // dead peer kills this process with SIGPIPE.
        try sendAll(fd, requestData)

        // Connected — any failure from here on means a wedged app, not an absent one.
        guard let header = readFully(fd, count: 4) else {
            throw Failure.unresponsive
        }
        let responseLength = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard responseLength > 0, responseLength <= 4 * 1024 * 1024 else {
            throw Failure.badResponse("bad frame length \(responseLength)")
        }
        guard let responseData = readFully(fd, count: Int(responseLength)) else {
            throw Failure.unresponsive  // mid-frame EOF or read timeout
        }
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else {
            throw Failure.badResponse("malformed frame")
        }
        return response
    }

    private static func sendAll(_ fd: Int32, _ data: Data) throws {
        var header = Data()
        var length = UInt32(data.count).bigEndian
        header.append(Data(bytes: &length, count: 4))
        header.append(data)
        try header.withUnsafeBytes { ptr in
            var sent = 0
            while sent < ptr.count {
                let n = send(fd, ptr.baseAddress! + sent, ptr.count - sent, MSG_NOSIGNAL)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.unresponsive  // EPIPE etc. — peer gone after connect
                }
                sent += n
            }
        }
    }

    private static func readFully(_ fd: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while data.count < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, min(ptr.count, count - data.count), 0)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }
}
