import Foundation

/// Small CBOR (RFC 8949) encoder and decoder. Only the types the Digital ID uses.
indirect enum CBOR {
    case unsigned(UInt64)
    case negative(UInt64)          // value is -1 - n
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(key: CBOR, value: CBOR)])
    case tagged(UInt64, CBOR)
    case bool(Bool)
    case null

    enum DecodeError: Error { case truncated, unsupported(UInt8), badText }

    // MARK: Reading values

    /// Value for a text key in a map.
    subscript(key: String) -> CBOR? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { if case .text(let k) = $0.key { return k == key }; return false }?.value
    }

    /// The value with any tags removed.
    var untagged: CBOR {
        if case .tagged(_, let inner) = self { return inner.untagged }
        return self
    }

    var text: String? { if case .text(let s) = untagged { return s }; return nil }
    var data: Data? { if case .bytes(let d) = untagged { return d }; return nil }
    var bool: Bool? { if case .bool(let b) = untagged { return b }; return nil }
    var int: Int? { if case .unsigned(let n) = untagged { return Int(n) }; return nil }

    // MARK: Encoding

    /// CBOR bytes, using the shortest length forms (same bytes the server makes).
    func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .unsigned(let n): Self.head(0, n, &out)
        case .negative(let n): Self.head(1, n, &out)
        case .bytes(let d): Self.head(2, UInt64(d.count), &out); out.append(d)
        case .text(let s): let d = Data(s.utf8); Self.head(3, UInt64(d.count), &out); out.append(d)
        case .array(let items): Self.head(4, UInt64(items.count), &out); items.forEach { $0.encode(into: &out) }
        case .map(let pairs):
            Self.head(5, UInt64(pairs.count), &out)
            pairs.forEach { $0.key.encode(into: &out); $0.value.encode(into: &out) }
        case .tagged(let tag, let inner): Self.head(6, tag, &out); inner.encode(into: &out)
        case .bool(let b): out.append(b ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        }
    }

    /// Major type and length/value in the shortest form.
    private static func head(_ major: UInt8, _ value: UInt64, _ out: inout Data) {
        let m = major << 5
        switch value {
        case 0..<24: out.append(m | UInt8(value))
        case 24...0xFF: out.append(m | 24); out.append(UInt8(value))
        case 0x100...0xFFFF: out.append(m | 25); appendBigEndian(UInt16(value), &out)
        case 0x10000...0xFFFF_FFFF: out.append(m | 26); appendBigEndian(UInt32(value), &out)
        default: out.append(m | 27); appendBigEndian(value, &out)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ v: T, _ out: inout Data) {
        withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) }
    }

    // MARK: Decoding

    /// Parses one CBOR value from the bytes.
    static func decode(_ data: Data) throws -> CBOR {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.value()
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() throws -> UInt8 {
            guard i < bytes.count else { throw DecodeError.truncated }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, i + n <= bytes.count else { throw DecodeError.truncated }
            defer { i += n }
            return Array(bytes[i..<i + n])
        }

        mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24: return UInt64(try byte())
            case 25: return try take(2).reduce(0) { $0 << 8 | UInt64($1) }
            case 26: return try take(4).reduce(0) { $0 << 8 | UInt64($1) }
            case 27: return try take(8).reduce(0) { $0 << 8 | UInt64($1) }
            default: throw DecodeError.unsupported(info)
            }
        }

        mutating func value() throws -> CBOR {
            let first = try byte()
            let major = first >> 5, info = first & 0x1F
            if major == 7 {
                switch info {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22, 23: return .null
                default: throw DecodeError.unsupported(first)
                }
            }
            let n = try argument(info)
            switch major {
            case 0: return .unsigned(n)
            case 1: return .negative(n)
            case 2: return .bytes(Data(try take(Int(n))))
            case 3:
                guard let s = String(bytes: try take(Int(n)), encoding: .utf8) else { throw DecodeError.badText }
                return .text(s)
            case 4: return .array(try (0..<n).map { _ in try value() })
            case 5: return .map(try (0..<n).map { _ in (key: try value(), value: try value()) })
            default: return .tagged(n, try value())
            }
        }
    }
}
