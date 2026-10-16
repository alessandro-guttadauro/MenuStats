import Darwin
import Foundation
import SystemConfiguration

struct NetworkStats {
    var interface: String?
    var ipAddress: String?
    var downloadRate: Double
    var uploadRate: Double
    var totalDownloaded: UInt64
    var totalUploaded: UInt64
}

/// Network throughput from 64-bit interface counters (sysctl NET_RT_IFLIST2),
/// measured on the primary interface reported by SystemConfiguration.
final class NetworkReader {
    private struct Counters {
        var received: UInt64
        var sent: UInt64
    }

    private let store = SCDynamicStoreCreate(nil, "MenuStats" as CFString, nil, nil)
    private var previous: (interface: String, counters: Counters, time: Double)?

    func sample() -> NetworkStats? {
        let all = readCounters()
        let interface = primaryInterface()
        let now = uptimeSeconds()

        // Without a primary interface (offline), fall back to the sum of all Ethernet/Wi-Fi ports.
        let key = interface ?? "en*"
        let current: Counters
        if let interface, let counters = all[interface] {
            current = counters
        } else {
            current = all.filter { $0.key.hasPrefix("en") }.values.reduce(Counters(received: 0, sent: 0)) {
                Counters(received: $0.received + $1.received, sent: $0.sent + $1.sent)
            }
        }
        defer { previous = (key, current, now) }

        var down = 0.0, up = 0.0
        if let previous, previous.interface == key, now > previous.time {
            let elapsed = now - previous.time
            down = Double(current.received &- previous.counters.received) / elapsed
            up = Double(current.sent &- previous.counters.sent) / elapsed
            // A counter reset (interface reconnect) would show up as a huge wrapped delta.
            if current.received < previous.counters.received { down = 0 }
            if current.sent < previous.counters.sent { up = 0 }
        }

        return NetworkStats(
            interface: interface,
            ipAddress: interface.flatMap(ipv4Address(of:)),
            downloadRate: down,
            uploadRate: up,
            totalDownloaded: current.received,
            totalUploaded: current.sent
        )
    }

    private func primaryInterface() -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        result[String(cString: name)] = Counters(
                            received: message.ifm_data.ifi_ibytes,
                            sent: message.ifm_data.ifi_obytes
                        )
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    private func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }

        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
