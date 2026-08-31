import Foundation

/// Finds this Mac's LAN addresses, so the pairing QR code can point the phone at the right place.
enum NetworkInterface {

    struct Address {
        let interface: String
        let ip: String
        /// Wi-Fi and Ethernet are what a phone can actually reach; everything else is noise.
        var isLikelyReachable: Bool {
            interface.hasPrefix("en")
        }
    }

    /// All non-loopback IPv4 addresses, best candidate first.
    static func localIPv4Addresses() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [Address] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            // Up, running, and not the loopback.
            guard flags & IFF_UP == IFF_UP,
                  flags & IFF_RUNNING == IFF_RUNNING,
                  flags & IFF_LOOPBACK == 0,
                  let addr = pointer.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let ip = String(cString: buffer)
            // Skip link-local self-assigned addresses; nothing can route to them usefully.
            guard !ip.hasPrefix("169.254.") else { continue }

            results.append(
                Address(interface: String(cString: pointer.pointee.ifa_name), ip: ip)
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.isLikelyReachable != rhs.isLikelyReachable { return lhs.isLikelyReachable }
            return lhs.interface < rhs.interface
        }
    }

    static func bestLocalAddress() -> String? {
        localIPv4Addresses().first?.ip
    }
}
