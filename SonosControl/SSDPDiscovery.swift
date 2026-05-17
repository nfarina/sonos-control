import Foundation
import Darwin

/// SSDP discovery via UDP M-SEARCH to 239.255.255.250:1900. We don't actually
/// need to join the multicast group as a receiver — Sonos players reply with
/// unicast UDP back to our source port, so we just need a writable socket.
enum SSDPDiscovery {

    struct Response {
        let location: URL
        let usn: String
        let server: String
        let household: String
        let sourceIP: String

        /// e.g. "RINCON_000E58XXXXXXX01400" extracted from
        /// "uuid:RINCON_000E58XXXXXXX01400::urn:schemas-upnp-org:..."
        var uuid: String? {
            guard let after = usn.range(of: "uuid:")?.upperBound else { return nil }
            let tail = usn[after...]
            if let stop = tail.range(of: "::") {
                return String(tail[..<stop.lowerBound])
            }
            return String(tail)
        }
    }

    /// Send one M-SEARCH and collect responses for `timeout` seconds.
    /// Returns one entry per unique source IP.
    static func discover(timeout: TimeInterval = 2.0) async -> [Response] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let responses = blockingDiscover(timeout: timeout)
                continuation.resume(returning: responses)
            }
        }
    }

    private static func blockingDiscover(timeout: TimeInterval) -> [Response] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            logError("SSDP: socket() failed")
            return []
        }
        defer { close(sock) }

        // Outbound multicast TTL — default is 1 which works for the local
        // subnet; bump to 4 to be safe across small networks.
        var ttl: u_char = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL,
                   &ttl, socklen_t(MemoryLayout<u_char>.size))

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,
                   &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to ephemeral port so we receive replies.
        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            logError("SSDP: bind() failed errno=\(errno)")
            return []
        }

        let mSearch = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """
        guard let data = mSearch.data(using: .utf8) else { return [] }

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = UInt16(1900).bigEndian
        destAddr.sin_addr.s_addr = inet_addr("239.255.255.250")

        // Send the M-SEARCH twice in quick succession — UDP can drop, and Sonos
        // dedupes by source.
        for _ in 0..<2 {
            data.withUnsafeBytes { raw in
                _ = withUnsafePointer(to: &destAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(sock, raw.baseAddress, raw.count, 0,
                               saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            usleep(50_000) // 50ms
        }

        // Receive replies with a deadline.
        var responses: [String: Response] = [:]    // dedupe by source IP
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var tv = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1)) * 1_000_000))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var srcAddr = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBufferPointer { bufPtr -> Int in
                withUnsafeMutablePointer(to: &srcAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        recvfrom(sock, bufPtr.baseAddress, bufPtr.count, 0, saPtr, &srcLen)
                    }
                }
            }
            if n <= 0 { break }

            let payload = Data(buf.prefix(n))
            guard let text = String(data: payload, encoding: .utf8) else { continue }

            let ip = String(cString: inet_ntoa(srcAddr.sin_addr))
            if let response = parseSSDPResponse(text, sourceIP: ip) {
                responses[ip] = response
            }
        }

        logInfo("SSDP: discovered \(responses.count) Sonos device(s): \(responses.keys.sorted().joined(separator: ", "))")
        return Array(responses.values)
    }

    private static func parseSSDPResponse(_ text: String, sourceIP: String) -> Response? {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        guard let server = headers["SERVER"], server.contains("Sonos") else { return nil }
        guard let locationStr = headers["LOCATION"], let location = URL(string: locationStr) else { return nil }
        let usn = headers["USN"] ?? ""
        let household = headers["X-RINCON-HOUSEHOLD"] ?? ""
        return Response(location: location, usn: usn, server: server, household: household, sourceIP: sourceIP)
    }
}
