import Foundation
import Network
import Darwin

/// A single-session HTTP endpoint. No filesystem paths, directory listing, uploads, or proxying.
final class StreamHTTPServer: @unchecked Sendable {
    private final class StartState: @unchecked Sendable { var resumed = false }
    private let queue = DispatchQueue(label: "com.airplayr.stream-http")
    private let resource: @Sendable (String) async throws -> (Data, String)?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var awaitingHeaders: Set<UUID> = []
    private var stopped = false
    init(resource: @escaping @Sendable (String) async throws -> (Data, String)?) { self.resource = resource }

    static func localAddress() throws -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw StreamFailure(message: "Could not find a local network. Connect the Mac and TV to the same network.") }
        defer { freeifaddrs(list) }
        var primary: [String] = []
        var fallback: [String] = []
        var cursor = list
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }
                if name.hasPrefix("en") { primary.append(ip) }
                else { fallback.append(ip) }
            }
        }
        if let address = primary.first ?? fallback.first { return address }
        throw StreamFailure(message: "Connect this Mac to Wi-Fi or Ethernet to prepare playback for your TV.")
    }

    func start(host: String? = nil) async throws -> URL {
        let address = try host ?? Self.localAddress()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    let state = StartState()
                    listener.stateUpdateHandler = { [weak listener, weak self] event in
                        guard let listener, let self else { return }
                        switch event {
                        case .ready:
                            guard !state.resumed, let port = listener.port,
                                  let url = URL(string: "http://\(address):\(port.rawValue)/\(self.token)/index.m3u8") else { return }
                            state.resumed = true; continuation.resume(returning: url)
                        case .failed(let error):
                            if !state.resumed { state.resumed = true; continuation.resume(throwing: error) }
                        case .cancelled:
                            if !state.resumed { state.resumed = true; continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 10) {
                        if !state.resumed {
                            state.resumed = true
                            continuation.resume(throwing: StreamFailure(message: "Local streaming could not start. Allow AirPlayr in System Settings → Privacy & Security → Local Network."))
                            listener.cancel()
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        if connections.count >= 24 {
            if let unauthenticated = awaitingHeaders.first {
                awaitingHeaders.remove(unauthenticated)
                connections.removeValue(forKey: unauthenticated)?.cancel()
            } else {
                connection.cancel(); return
            }
        }
        let id = UUID(); connections[id] = connection
        awaitingHeaders.insert(id)
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, self.awaitingHeaders.remove(id) != nil else { return }
            connection?.cancel(); self.connections.removeValue(forKey: id)
        }
        queue.asyncAfter(deadline: .now() + 60) { [weak self, weak connection] in
            connection?.cancel(); self?.connections.removeValue(forKey: id); self?.requests.removeValue(forKey: id)?.cancel()
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated; if let data { request.append(data) }
            if request.count > 8192 { self.send(connection, id: id, status: 431); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, id: id, request: request)
            } else if complete || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
            else { self.receive(connection, id: id, accumulated: request) }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, request: Data) {
        awaitingHeaders.remove(id)
        guard let text = String(data: request, encoding: .utf8) else { send(connection, id: id, status: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else { send(connection, id: id, status: 405); return }
        let prefix = "/\(token)/"
        let path = String(fields[1])
        guard path.hasPrefix(prefix) else { send(connection, id: id, status: 404); return }
        let name = String(path.dropFirst(prefix.count))
        guard !name.contains("/"), !name.contains("%") else { send(connection, id: id, status: 404); return }
        let head = fields[0] == "HEAD"
        let range = lines.first(where: { $0.lowercased().hasPrefix("range:") })
        requests[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.resource(name)
                try Task.checkCancellation()
                self.queue.async { [self] in
                    self.requests[id] = nil
                    guard self.connections[id] != nil, !self.stopped else { return }
                    guard let (data, mime) = result else { self.send(connection, id: id, status: 404); return }
                    if let range {
                        guard let bounds = Self.byteRange(range, count: data.count) else {
                            self.send(connection, id: id, status: 416, extra: "Content-Range: bytes */\(data.count)\r\n"); return
                        }
                        self.send(connection, id: id, status: 206, data: data.subdata(in: bounds), mime: mime, head: head, extra: "Content-Range: bytes \(bounds.lowerBound)-\(bounds.upperBound-1)/\(data.count)\r\n")
                    } else { self.send(connection, id: id, status: 200, data: data, mime: mime, head: head) }
                }
            } catch {
                self.queue.async { [self] in
                    self.requests[id] = nil
                    if self.connections[id] != nil { self.send(connection, id: id, status: 503) }
                }
            }
        }
    }
    static func byteRange(_ header: String, count: Int) -> Range<Int>? {
        guard count > 0, let marker = header.range(of: "bytes="), !header.contains(",") else { return nil }
        let fields = header[marker.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        if fields[0].isEmpty {
            guard let suffix = Int(fields[1]), suffix > 0 else { return nil }
            return max(0, count-suffix)..<count
        }
        guard let start = Int(fields[0]), start >= 0, start < count else { return nil }
        let end = fields[1].isEmpty ? count-1 : Int(fields[1]) ?? -1
        guard end >= start else { return nil }
        return start..<(min(end, count-1)+1)
    }
    private func send(_ connection: NWConnection, id: UUID, status: Int, data: Data = Data(), mime: String = "text/plain", head: Bool = false, extra: String = "") {
        let names = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        let header = "HTTP/1.1 \(status) \(names[status] ?? "Error")\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        var response = Data(header.utf8); if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.queue.async { self?.connections.removeValue(forKey: id) }
        })
    }
    func stop() { queue.async { self.stopped = true; self.listener?.cancel(); self.listener = nil; self.connections.values.forEach { $0.cancel() }; self.connections.removeAll(); self.requests.values.forEach { $0.cancel() }; self.requests.removeAll() } }
    deinit { listener?.cancel() }
}

/// Lightweight HTTP server that streams a single local file via standard RFC 7233 range requests.
/// Allows AirPlay 2 receivers (Apple TV, Samsung, LG, Roku) and Cast/DLNA targets to fetch sandboxed local files.
final class StreamFileServer: @unchecked Sendable {
    private final class StartState: @unchecked Sendable { var resumed = false }
    private let queue = DispatchQueue(label: "com.airplayr.stream-file", qos: .userInitiated)
    private let fileURL: URL
    private let fileSize: Int
    private let mimeType: String
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        self.fileSize = max(0, size)

        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": self.mimeType = "video/mp4"
        case "mov": self.mimeType = "video/quicktime"
        case "mp3": self.mimeType = "audio/mpeg"
        case "m4a", "aac": self.mimeType = "audio/mp4"
        case "wav": self.mimeType = "audio/wav"
        case "flac": self.mimeType = "audio/flac"
        default: self.mimeType = "video/mp4"
        }
    }

    func start(host: String? = nil) async throws -> URL {
        let address: String
        do {
            address = try host ?? StreamHTTPServer.localAddress()
        } catch {
            address = "127.0.0.1"
        }
        let filename = fileURL.lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    let state = StartState()
                    listener.stateUpdateHandler = { [weak listener, weak self] event in
                        guard let listener, let self else { return }
                        switch event {
                        case .ready:
                            guard !state.resumed, let port = listener.port,
                                  let cleanName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                                  let url = URL(string: "http://\(address):\(port.rawValue)/\(self.token)/\(cleanName)") else { return }
                            state.resumed = true
                            continuation.resume(returning: url)
                        case .failed(let error):
                            if !state.resumed { state.resumed = true; continuation.resume(throwing: error) }
                        case .cancelled:
                            if !state.resumed { state.resumed = true; continuation.resume(throwing: CancellationError()) }
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 10) {
                        if !state.resumed {
                            state.resumed = true
                            continuation.resume(throwing: StreamFailure(message: "Local media server could not start. Check Local Network permissions."))
                            listener.cancel()
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
        queue.asyncAfter(deadline: .now() + 60) { [weak self, weak connection] in
            connection?.cancel()
            self?.connections.removeValue(forKey: id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            if request.count > 8192 { self.send(connection, id: id, status: 431); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, id: id, request: request)
            } else if complete || error != nil {
                connection.cancel()
                self.connections.removeValue(forKey: id)
            } else {
                self.receive(connection, id: id, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { send(connection, id: id, status: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        let fields = (lines.first ?? "").split(separator: " ")
        guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else { send(connection, id: id, status: 405); return }
        let path = String(fields[1])
        guard path.contains("/\(token)/") else { send(connection, id: id, status: 404); return }
        let head = fields[0] == "HEAD"
        let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range:") })

        if head {
            sendHeaderOnly(connection, id: id, status: 200, count: fileSize)
            return
        }

        if let rangeHeader, let range = StreamHTTPServer.byteRange(rangeHeader, count: fileSize) {
            let length = range.count
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                send(connection, id: id, status: 404)
                return
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(range.lowerBound))
            let chunk = handle.readData(ofLength: min(length, 4 * 1024 * 1024))
            let extra = "Content-Range: bytes \(range.lowerBound)-\(range.lowerBound + chunk.count - 1)/\(fileSize)\r\n"
            send(connection, id: id, status: 206, data: chunk, extra: extra)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                send(connection, id: id, status: 404)
                return
            }
            defer { try? handle.close() }
            let readSize = min(fileSize, 4 * 1024 * 1024)
            let chunk = handle.readData(ofLength: readSize)
            if readSize < fileSize {
                let extra = "Content-Range: bytes 0-\(readSize - 1)/\(fileSize)\r\n"
                send(connection, id: id, status: 206, data: chunk, extra: extra)
            } else {
                send(connection, id: id, status: 200, data: chunk)
            }
        }
    }

    private func sendHeaderOnly(_ connection: NWConnection, id: UUID, status: Int, count: Int) {
        let header = "HTTP/1.1 \(status) OK\r\nContent-Type: \(mimeType)\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: id)
        })
    }

    private func send(_ connection: NWConnection, id: UUID, status: Int, data: Data = Data(), extra: String = "") {
        let statusText = status == 200 ? "OK" : (status == 206 ? "Partial Content" : "Error")
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(mimeType)\r\nContent-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: id)
        })
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    deinit {
        stop()
    }
}
