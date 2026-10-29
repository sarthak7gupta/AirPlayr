import Foundation
import Network
import Security
import AppKit
import Observation
import Darwin

/// Supported non-AirPlay wireless receiver protocols.
enum CastReceiverKind: String, Codable, CaseIterable, Sendable {
    case chromecast = "Chromecast"
    case miracastDLNA = "Miracast / DLNA"
}

/// A discovered or user-specified Chromecast or Miracast/DLNA receiver on the local network.
struct CastReceiverDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String
    let kind: CastReceiverKind
    let endpoint: NWEndpoint?
    let host: String?
    let port: UInt16
    let controlURL: URL?
}

/// Pure Swift CastV2 Protobuf wire framing (`extensions.api.cast_channel.CastMessage`) and JSON command payloads.
enum CastV2Protocol {
    static let defaultMediaReceiverAppID = "CC1AD845"
    static let connectionNamespace = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeatNamespace = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiverNamespace = "urn:x-cast:com.google.cast.receiver"
    static let mediaNamespace = "urn:x-cast:com.google.cast.media"

    struct Message: Equatable, Sendable {
        var sourceID: String = "sender-0"
        var destinationID: String = "receiver-0"
        var namespace: String
        var payloadUTF8: String
    }

    /// Encodes a `CastMessage` into a 4-byte big-endian length-prefixed Protobuf packet.
    static func encode(_ message: Message) -> Data {
        var body = Data()
        // Field 1: protocol_version = 0 (varint, tag 0x08)
        body.append(contentsOf: [0x08, 0x00])
        // Field 2: source_id (length-delimited string, tag 0x12)
        appendString(message.sourceID, tag: 0x12, to: &body)
        // Field 3: destination_id (length-delimited string, tag 0x1A)
        appendString(message.destinationID, tag: 0x1A, to: &body)
        // Field 4: namespace (length-delimited string, tag 0x22)
        appendString(message.namespace, tag: 0x22, to: &body)
        // Field 5: payload_type = 0 (STRING, varint, tag 0x28)
        body.append(contentsOf: [0x28, 0x00])
        // Field 6: payload_utf8 (length-delimited string, tag 0x32)
        appendString(message.payloadUTF8, tag: 0x32, to: &body)

        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)
        return packet
    }

    /// Decodes a 4-byte length-prefixed Protobuf `CastMessage` packet.
    static func decode(_ packet: Data) -> Message? {
        guard packet.count >= 4 else { return nil }
        let length = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard packet.count >= 4 + Int(length) else { return nil }
        let bytes = Array(packet.dropFirst(4).prefix(Int(length)))
        var index = 0
        var sourceID = ""
        var destinationID = ""
        var namespace = ""
        var payloadUTF8 = ""
        while index < bytes.count {
            guard let tag = readVarint(bytes, index: &index) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07
            switch wireType {
            case 0:
                guard readVarint(bytes, index: &index) != nil else { return nil }
            case 2:
                guard let count = readVarint(bytes, index: &index), index + Int(count) <= bytes.count else { return nil }
                let text = String(decoding: bytes[index..<(index + Int(count))], as: UTF8.self)
                index += Int(count)
                switch fieldNumber {
                case 2: sourceID = text
                case 3: destinationID = text
                case 4: namespace = text
                case 6: payloadUTF8 = text
                default: break
                }
            default:
                return nil
            }
        }
        guard !namespace.isEmpty else { return nil }
        return Message(sourceID: sourceID, destinationID: destinationID, namespace: namespace, payloadUTF8: payloadUTF8)
    }

    static func loadPayload(requestID: Int, mediaSessionUrl: URL, title: String, position: Double) -> String {
        let escapedURL = jsonEscape(mediaSessionUrl.absoluteString)
        let escapedTitle = jsonEscape(title)
        let start = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, position))
        return #"{"type":"LOAD","requestId":\#(requestID),"autoplay":true,"currentTime":\#(start),"media":{"contentId":"\#(escapedURL)","streamType":"BUFFERED","contentType":"application/vnd.apple.mpegurl","metadata":{"metadataType":1,"title":"\#(escapedTitle)"}}}"#
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func dlnaSetAVTransportSOAP(streamURL: URL, title: String) -> Data {
        let uri = xmlEscape(streamURL.absoluteString)
        let safeTitle = xmlEscape(title)
        let metadata = xmlEscape("""
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>\(safeTitle)</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:application/vnd.apple.mpegurl:*">\(uri)</res></item></DIDL-Lite>
        """)
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
        <InstanceID>0</InstanceID>
        <CurrentURI>\(uri)</CurrentURI>
        <CurrentURIMetaData>\(metadata)</CurrentURIMetaData>
        </u:SetAVTransportURI>
        </s:Body>
        </s:Envelope>
        """
        return Data(envelope.utf8)
    }

    static func dlnaActionSOAP(_ action: String, arguments: String = "<Speed>1</Speed>") -> Data {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:\(action) xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
        <InstanceID>0</InstanceID>
        \(arguments)
        </u:\(action)>
        </s:Body>
        </s:Envelope>
        """
        return Data(envelope.utf8)
    }

    /// Parses the `LOCATION:` header URL from a raw SSDP UDP response packet.
    static func parseSSDPLocation(_ response: String) -> URL? {
        for rawLine in response.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("location:") else { continue }
            let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), url.scheme?.lowercased() == "http", url.host != nil else { continue }
            return url
        }
        return nil
    }

    /// Parses a UPnP MediaRenderer XML description into a `CastReceiverDevice` with its resolved `AVTransport` control URL.
    static func parseUPnPDeviceXML(_ data: Data, baseURL: URL) -> CastReceiverDevice? {
        guard data.count <= 512_000, let xml = String(data: data, encoding: .utf8),
              let host = baseURL.host else { return nil }
        let friendlyName = extractXMLTag("friendlyName", in: xml) ?? "DLNA TV (\(host))"
        let modelName = extractXMLTag("modelName", in: xml) ?? CastReceiverKind.miracastDLNA.rawValue
        var resolvedControlPath: String?
        let serviceBlocks = xml.components(separatedBy: "<service>")
        for block in serviceBlocks.dropFirst() {
            guard let serviceEnd = block.range(of: "</service>") else { continue }
            let serviceXML = String(block[..<serviceEnd.lowerBound])
            guard let serviceType = extractXMLTag("serviceType", in: serviceXML),
                  serviceType.contains("urn:schemas-upnp-org:service:AVTransport:"),
                  let controlRaw = extractXMLTag("controlURL", in: serviceXML), !controlRaw.isEmpty else { continue }
            resolvedControlPath = controlRaw
            break
        }
        guard let controlRaw = resolvedControlPath else { return nil }
        let controlURL: URL?
        if let absolute = URL(string: controlRaw), absolute.scheme != nil {
            controlURL = absolute
        } else {
            var components = URLComponents()
            components.scheme = baseURL.scheme ?? "http"
            components.host = host
            components.port = baseURL.port ?? 80
            components.path = controlRaw.hasPrefix("/") ? controlRaw : "/" + controlRaw
            controlURL = components.url
        }
        guard let controlURL else { return nil }
        let port = UInt16(clamping: controlURL.port ?? baseURL.port ?? 80)
        return CastReceiverDevice(
            id: "ssdp-\(host):\(port)-\(controlURL.path)",
            name: friendlyName,
            model: modelName,
            kind: .miracastDLNA,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 80),
            host: host,
            port: port,
            controlURL: controlURL
        )
    }

    private static func extractXMLTag(_ tag: String, in xml: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)>", options: .caseInsensitive),
              let endRange = xml.range(of: "</\(tag)>", options: .caseInsensitive, range: startRange.upperBound..<xml.endIndex) else {
            return nil
        }
        let raw = String(xml[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func jsonEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func appendString(_ string: String, tag: UInt8, to data: inout Data) {
        let utf8 = Data(string.utf8)
        data.append(tag)
        appendVarint(UInt64(utf8.count), to: &data)
        data.append(utf8)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var current = value
        while current >= 0x80 {
            data.append(UInt8((current & 0x7F) | 0x80))
            current >>= 7
        }
        data.append(UInt8(current))
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { return result }
            shift += 7
        }
        return nil
    }
}

/// Discovers and controls Chromecast (`_googlecast._tcp`) and Miracast/DLNA receivers over the local network.
@MainActor @Observable final class CastService {
    private(set) var devices: [CastReceiverDevice] = []
    private(set) var activeDevice: CastReceiverDevice?
    private(set) var statusMessage: String?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var ssdpTask: Task<Void, Never>?
    @ObservationIgnored private var chromecastDevices: [CastReceiverDevice] = []
    @ObservationIgnored private var ssdpDevices: [CastReceiverDevice] = []
    @ObservationIgnored private var manualDevices: [CastReceiverDevice] = []
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var transportID: String?
    @ObservationIgnored private var mediaSessionID: Int?
    @ObservationIgnored private var requestID = 1
    @ObservationIgnored private let queue = DispatchQueue(label: "com.airplayr.cast-service")

    private func rebuildDevices() {
        var combined: [CastReceiverDevice] = []
        var seen: Set<String> = []
        for list in [chromecastDevices, ssdpDevices, manualDevices] {
            for device in list where seen.insert(device.id).inserted {
                combined.append(device)
            }
        }
        devices = combined
    }

    func startDiscovery() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var discovered: [CastReceiverDevice] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                var friendlyName = name
                var model = "Chromecast"
                if case let .bonjour(txt) = result.metadata {
                    if let fn = txt.dictionary["fn"], !fn.isEmpty { friendlyName = fn }
                    if let md = txt.dictionary["md"], !md.isEmpty { model = md }
                }
                discovered.append(CastReceiverDevice(
                    id: "chromecast-\(name)",
                    name: friendlyName,
                    model: model,
                    kind: .chromecast,
                    endpoint: result.endpoint,
                    host: nil,
                    port: 8009,
                    controlURL: nil
                ))
            }
            let sorted = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chromecastDevices = sorted
                self.rebuildDevices()
            }
        }
        browser.start(queue: queue)
        ssdpTask?.cancel()
        ssdpTask = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Self.performSSDPSweep()
                guard !Task.isCancelled, let self else { break }
                if !found.isEmpty {
                    self.ssdpDevices = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.rebuildDevices()
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        ssdpTask?.cancel()
        ssdpTask = nil
    }

    private static func performSSDPSweep() async -> [CastReceiverDevice] {
        let ssdpEnabled = (UserDefaults.standard.object(forKey: "ssdpDiscoveryEnabled") as? Bool) ?? true
        guard ssdpEnabled else { return [] }
        let locations = await Task.detached(priority: .utility) { () -> [URL] in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(1900).bigEndian
            _ = "239.255.255.250".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

            let searchTargets = [
                "urn:schemas-upnp-org:device:MediaRenderer:1",
                "urn:schemas-upnp-org:service:AVTransport:1"
            ]
            for st in searchTargets {
                let payload = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
                let bytes = Array(payload.utf8)
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        _ = sendto(fd, bytes, bytes.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            var urls: [URL] = []
            var seen: Set<String> = []
            let deadline = Date().addingTimeInterval(2.0)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline, !Task.isCancelled {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { continue }
                let text = String(decoding: buffer[0..<n], as: UTF8.self)
                if let url = CastV2Protocol.parseSSDPLocation(text),
                   seen.insert(url.absoluteString).inserted {
                    urls.append(url)
                }
            }
            return urls
        }.value

        var discovered: [CastReceiverDevice] = []
        var seenIDs: Set<String> = []
        for location in locations.prefix(12) {
            if Task.isCancelled { break }
            var request = URLRequest(url: location, timeoutInterval: 3)
            request.httpMethod = "GET"
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let device = CastV2Protocol.parseUPnPDeviceXML(data, baseURL: location),
                  seenIDs.insert(device.id).inserted else { continue }
            discovered.append(device)
        }
        return discovered
    }

    @discardableResult
    func addManualDevice(name: String, host: String, port: UInt16? = nil, kind: CastReceiverKind, controlPath: String = "/upnp/control/AVTransport1") -> CastReceiverDevice {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = port ?? (kind == .chromecast ? 8009 : 1400)
        let displayName = trimmedName.isEmpty ? "\(kind.rawValue) (\(trimmedHost))" : trimmedName
        let controlURL = kind == .miracastDLNA ? URL(string: "http://\(trimmedHost):\(resolvedPort)\(controlPath)") : nil
        let device = CastReceiverDevice(
            id: "manual-\(kind.rawValue)-\(trimmedHost):\(resolvedPort)",
            name: displayName,
            model: kind.rawValue,
            kind: kind,
            endpoint: .hostPort(host: NWEndpoint.Host(trimmedHost), port: NWEndpoint.Port(rawValue: resolvedPort) ?? 8009),
            host: trimmedHost,
            port: resolvedPort,
            controlURL: controlURL
        )
        manualDevices.removeAll { $0.id == device.id }
        manualDevices.append(device)
        rebuildDevices()
        return device
    }

    func connect(_ device: CastReceiverDevice, streamURL: URL, title: String, position: Double) {
        disconnect()
        activeDevice = device
        statusMessage = "Connecting to \(device.name) (\(device.kind.rawValue))…"
        switch device.kind {
        case .chromecast:
            connectChromecast(device, streamURL: streamURL, title: title, position: position)
        case .miracastDLNA:
            connectDLNA(device, streamURL: streamURL, title: title)
        }
    }

    func sendPlaybackState(playing: Bool) {
        guard let activeDevice else { return }
        switch activeDevice.kind {
        case .chromecast:
            guard let transportID, let mediaSessionID else { return }
            let command = playing ? "PLAY" : "PAUSE"
            sendChromecast(destination: transportID, namespace: CastV2Protocol.mediaNamespace, payload: #"{"type":"\#(command)","mediaSessionId":\#(mediaSessionID),"requestId":\#(nextRequestID())}"#)
        case .miracastDLNA:
            guard let controlURL = activeDevice.controlURL else { return }
            let action = playing ? "Play" : "Pause"
            let args = playing ? "<Speed>1</Speed>" : ""
            Task { try? await Self.sendSOAP(to: controlURL, action: action, body: CastV2Protocol.dlnaActionSOAP(action, arguments: args)) }
        }
    }

    func sendSeek(to seconds: Double) {
        guard let activeDevice else { return }
        switch activeDevice.kind {
        case .chromecast:
            guard let transportID, let mediaSessionID else { return }
            let formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
            sendChromecast(destination: transportID, namespace: CastV2Protocol.mediaNamespace, payload: #"{"type":"SEEK","mediaSessionId":\#(mediaSessionID),"currentTime":\#(formatted),"requestId":\#(nextRequestID())}"#)
        case .miracastDLNA:
            guard let controlURL = activeDevice.controlURL else { return }
            let total = Int(max(0, seconds))
            let target = String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            let body = CastV2Protocol.dlnaActionSOAP("Seek", arguments: "<Unit>REL_TIME</Unit><Target>\(target)</Target>")
            Task { try? await Self.sendSOAP(to: controlURL, action: "Seek", body: body) }
        }
    }

    func disconnect() {
        if let activeDevice {
            switch activeDevice.kind {
            case .chromecast:
                if let transportID {
                    sendChromecast(destination: transportID, namespace: CastV2Protocol.connectionNamespace, payload: #"{"type":"CLOSE"}"#)
                }
            case .miracastDLNA:
                if let controlURL = activeDevice.controlURL {
                    Task { try? await Self.sendSOAP(to: controlURL, action: "Stop", body: CastV2Protocol.dlnaActionSOAP("Stop", arguments: "")) }
                }
            }
        }
        connection?.cancel()
        connection = nil
        transportID = nil
        mediaSessionID = nil
        activeDevice = nil
        statusMessage = nil
    }

    func openSystemMirroringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func nextRequestID() -> Int {
        defer { requestID += 1 }
        return requestID
    }

    private func connectChromecast(_ device: CastReceiverDevice, streamURL: URL, title: String, position: Double) {
        guard let endpoint = device.endpoint else {
            statusMessage = "Could not resolve Chromecast address."
            return
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completion in
            // Cast hardware uses a device-signed certificate on LAN port 8009.
            completion(true)
        }, queue)
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(to: endpoint, using: parameters)
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.statusMessage = "Connected to \(device.name) • launching media receiver…"
                    self.sendChromecast(destination: "receiver-0", namespace: CastV2Protocol.connectionNamespace, payload: #"{"type":"CONNECT"}"#)
                    self.sendChromecast(destination: "receiver-0", namespace: CastV2Protocol.receiverNamespace, payload: #"{"type":"LAUNCH","appId":"\#(CastV2Protocol.defaultMediaReceiverAppID)","requestId":\#(self.nextRequestID())}"#)
                    self.receiveChromecastLoop(conn, streamURL: streamURL, title: title, position: position)
                case .failed:
                    self.statusMessage = "Could not connect to \(device.name). Check that your TV and Mac are on the same network."
                    self.activeDevice = nil
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func receiveChromecastLoop(_ conn: NWConnection, streamURL: URL, title: String, position: Double) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, let message = CastV2Protocol.decode(data) {
                Task { @MainActor [weak self] in
                    self?.handleChromecastMessage(message, streamURL: streamURL, title: title, position: position)
                }
            }
            if !isComplete, error == nil {
                Task { @MainActor [weak self] in
                    self?.receiveChromecastLoop(conn, streamURL: streamURL, title: title, position: position)
                }
            }
        }
    }

    private func handleChromecastMessage(_ message: CastV2Protocol.Message, streamURL: URL, title: String, position: Double) {
        if message.namespace == CastV2Protocol.heartbeatNamespace, message.payloadUTF8.contains("PING") {
            sendChromecast(destination: message.sourceID, namespace: CastV2Protocol.heartbeatNamespace, payload: #"{"type":"PONG"}"#)
            return
        }
        if message.namespace == CastV2Protocol.receiverNamespace,
           let json = try? JSONSerialization.jsonObject(with: Data(message.payloadUTF8.utf8)) as? [String: Any],
           let status = json["status"] as? [String: Any],
           let apps = status["applications"] as? [[String: Any]],
           let app = apps.first(where: { ($0["appId"] as? String) == CastV2Protocol.defaultMediaReceiverAppID }),
           let transport = app["transportId"] as? String,
           transportID != transport {
            transportID = transport
            sendChromecast(destination: transport, namespace: CastV2Protocol.connectionNamespace, payload: #"{"type":"CONNECT"}"#)
            let payload = CastV2Protocol.loadPayload(requestID: nextRequestID(), mediaSessionUrl: streamURL, title: title, position: position)
            sendChromecast(destination: transport, namespace: CastV2Protocol.mediaNamespace, payload: payload)
            if let name = activeDevice?.name {
                statusMessage = "Streaming to \(name) (Chromecast)"
            }
            return
        }
        if message.namespace == CastV2Protocol.mediaNamespace,
           let json = try? JSONSerialization.jsonObject(with: Data(message.payloadUTF8.utf8)) as? [String: Any],
           let statuses = json["status"] as? [[String: Any]],
           let first = statuses.first,
           let sessionID = first["mediaSessionId"] as? Int {
            mediaSessionID = sessionID
        }
    }

    private func sendChromecast(destination: String, namespace: String, payload: String) {
        guard let connection else { return }
        let frame = CastV2Protocol.encode(CastV2Protocol.Message(destinationID: destination, namespace: namespace, payloadUTF8: payload))
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func connectDLNA(_ device: CastReceiverDevice, streamURL: URL, title: String) {
        guard let controlURL = device.controlURL else {
            statusMessage = "Missing control endpoint for \(device.name)."
            activeDevice = nil
            return
        }
        Task {
            do {
                try await Self.sendSOAP(to: controlURL, action: "SetAVTransportURI", body: CastV2Protocol.dlnaSetAVTransportSOAP(streamURL: streamURL, title: title))
                try await Self.sendSOAP(to: controlURL, action: "Play", body: CastV2Protocol.dlnaActionSOAP("Play"))
                statusMessage = "Streaming to \(device.name) (Miracast / DLNA)"
            } catch {
                statusMessage = "Could not start playback on \(device.name). Verify receiver IP and Local Network permission."
                activeDevice = nil
            }
        }
    }

    private static func sendSOAP(to url: URL, action: String, body: Data) async throws {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw StreamFailure(message: "Receiver rejected SOAP \(action)")
        }
    }
}
