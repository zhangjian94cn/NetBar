import Darwin
import Foundation

/// Detects whether a TUN-like interface is actually capturing broad traffic.
/// Existing utun interfaces alone are not enough: macOS and other tools may
/// keep utun interfaces around for narrow routes or local multicast traffic.
enum TunnelRouteDetector {
    struct IPv4Route: Equatable {
        let destination: String
        let interface: String
    }

    static let vpnPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]

    static func activeTunnelInterfaces() -> Set<String> {
        activeTunnelInterfaces(
            in: fetchIPv4Routes(),
            activeInterfaces: Set(activeVPNInterfaces())
        )
    }

    static func activeTunnelRouteDescriptions() -> [String] {
        activeTunnelRoutes(
            in: fetchIPv4Routes(),
            activeInterfaces: Set(activeVPNInterfaces())
        )
        .map { "\($0.destination) -> \($0.interface)" }
    }

    static func activeTunnelInterfaces(
        in routes: [IPv4Route],
        activeInterfaces: Set<String>? = nil
    ) -> Set<String> {
        Set(activeTunnelRoutes(in: routes, activeInterfaces: activeInterfaces).map(\.interface))
    }

    static func activeTunnelRoutes(
        in routes: [IPv4Route],
        activeInterfaces: Set<String>? = nil
    ) -> [IPv4Route] {
        var result: [IPv4Route] = []
        var seen: Set<String> = []

        for route in routes {
            guard isVPNInterfaceName(route.interface),
                  isTrafficCapturingRoute(route.destination) else {
                continue
            }

            if let activeInterfaces, !activeInterfaces.contains(route.interface) {
                continue
            }

            let key = "\(route.destination)|\(route.interface)"
            if seen.insert(key).inserted {
                result.append(route)
            }
        }

        return result
    }

    static func parseIPv4Routes(_ output: String) -> [IPv4Route] {
        output
            .components(separatedBy: .newlines)
            .compactMap(parseRouteLine)
    }

    static func parseRouteLine(_ line: String) -> IPv4Route? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 4 else { return nil }

        let destination = parts[0]
        let interface = parts[3]
        guard isVPNInterfaceName(interface) else { return nil }

        return IPv4Route(destination: destination, interface: interface)
    }

    static func isVPNInterfaceName(_ name: String) -> Bool {
        vpnPrefixes.contains { name.hasPrefix($0) }
    }

    static func isTrafficCapturingRoute(_ destination: String) -> Bool {
        if destination == "default" ||
           destination == "0/1" ||
           destination == "1" ||
           destination == "128.0/1" {
            return true
        }

        let broadCIDRs: Set<String> = [
            "2/7", "4/6", "8/7", "11", "12/6", "16/4", "32/3", "64/2",
            "128.0/3", "160.0/5", "168.0/6", "172.0/12", "172.32/11",
            "172.64/10", "172.128/9", "173.0/8", "174.0/7", "176.0/4",
            "192.0.0/2"
        ]
        return broadCIDRs.contains(destination)
    }

    private static func fetchIPv4Routes() -> [IPv4Route] {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return parseIPv4Routes(output)
    }

    private static func activeVPNInterfaces() -> [String] {
        var vpnInterfaces: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            if isUp,
               isVPNInterfaceName(name),
               hasIPv4Address(ptr.pointee.ifa_addr),
               !vpnInterfaces.contains(name) {
                vpnInterfaces.append(name)
            }

            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        return vpnInterfaces
    }

    private static func hasIPv4Address(_ address: UnsafeMutablePointer<sockaddr>?) -> Bool {
        guard let address, Int32(address.pointee.sa_family) == AF_INET else {
            return false
        }

        let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let hostOrderAddress = UInt32(bigEndian: ipv4.sin_addr.s_addr)
        let firstOctet = (hostOrderAddress >> 24) & 0xff
        let secondOctet = (hostOrderAddress >> 16) & 0xff

        return firstOctet != 127 && !(firstOctet == 169 && secondOctet == 254)
    }
}
