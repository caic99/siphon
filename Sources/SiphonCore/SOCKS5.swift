import Foundation

/// SOCKS5 (RFC 1928) client side, no authentication — what `ssh -D` serves.
/// The wire format lives here as pure functions so it can be tested without a
/// socket; `SOCKS5Dialer` drives them over a connection.
public enum SOCKS5 {
    public enum Error: Swift.Error, Equatable {
        case badVersion
        case noAcceptableAuth
        case hostnameTooLong
        case refused(code: UInt8)
        case truncated
    }

    /// Greeting: version 5, one method offered, 0x00 = no auth.
    public static let greeting = Data([0x05, 0x01, 0x00])

    /// Server's choice of method. Anything but 0x00 is a refusal.
    public static func checkGreetingReply(_ data: Data) throws {
        guard data.count >= 2 else { throw Error.truncated }
        guard data[data.startIndex] == 0x05 else { throw Error.badVersion }
        guard data[data.startIndex + 1] == 0x00 else { throw Error.noAcceptableAuth }
    }

    /// CONNECT request. Hostnames are sent as ATYP 0x03 so the far end resolves
    /// them — that is the whole point of tunnelling DNS too.
    public static func connectRequest(host: String, port: UInt16) throws -> Data {
        let name = Data(host.utf8)
        guard name.count <= 255 else { throw Error.hostnameTooLong }
        var out = Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)])
        out.append(name)
        out.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xff)])
        return out
    }

    public enum ReplyParse: Equatable {
        /// Need at least this many bytes in total before deciding.
        case needMore(Int)
        /// Connected; `consumed` bytes belonged to the reply, the rest is payload.
        case connected(consumed: Int)
    }

    /// Reply: VER REP RSV ATYP BND.ADDR BND.PORT, where BND.ADDR's length
    /// depends on ATYP. Returns how many bytes the reply occupied so any bytes
    /// the server optimistically sent after it are not lost.
    public static func parseConnectReply(_ data: Data) throws -> ReplyParse {
        guard data.count >= 4 else { return .needMore(4) }
        let b = Array(data.prefix(4))
        guard b[0] == 0x05 else { throw Error.badVersion }
        guard b[1] == 0x00 else { throw Error.refused(code: b[1]) }
        let addressLength: Int
        switch b[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03:
            guard data.count >= 5 else { return .needMore(5) }
            addressLength = 1 + Int(data[data.startIndex + 4])
        default: throw Error.badVersion
        }
        let total = 4 + addressLength + 2
        guard data.count >= total else { return .needMore(total) }
        return .connected(consumed: total)
    }

    /// What `refused(code:)` means, for the user.
    public static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "general SOCKS failure"
        case 0x02: return "connection not allowed by ruleset"
        case 0x03: return "network unreachable"
        case 0x04: return "host unreachable"
        case 0x05: return "connection refused"
        case 0x06: return "TTL expired"
        case 0x07: return "command not supported"
        case 0x08: return "address type not supported"
        default: return "SOCKS error \(code)"
        }
    }
}
