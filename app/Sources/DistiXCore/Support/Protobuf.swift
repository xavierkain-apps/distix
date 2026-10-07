import Foundation

/// Lecture minimale du format protobuf, sans schéma : assez pour retrouver des
/// champs dont on connaît le chemin (voir docs/schema-whatsapp.md).
public enum Protobuf {
    public enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed(Data)
    }

    public struct Field {
        public let number: Int
        public let value: Value
    }

    enum ParseError: Error { case malformed }

    public static func parse(_ data: Data) throws -> [Field] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift <= 63 else { throw ParseError.malformed }
                let b = bytes[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }
        while i < bytes.count {
            let key = try varint()
            let number = Int(key >> 3)
            guard number > 0 else { throw ParseError.malformed }
            switch key & 7 {
            case 0:
                out.append(Field(number: number, value: .varint(try varint())))
            case 1, 5:
                let n = key & 7 == 1 ? 8 : 4
                guard i + n <= bytes.count else { throw ParseError.malformed }
                out.append(Field(number: number, value: .fixed(Data(bytes[i..<i + n]))))
                i += n
            case 2:
                let n = Int(try varint())
                guard n >= 0, i + n <= bytes.count else { throw ParseError.malformed }
                out.append(Field(number: number, value: .bytes(Data(bytes[i..<i + n]))))
                i += n
            default:
                throw ParseError.malformed
            }
        }
        return out
    }

    /// Chaînes UTF-8 lisibles, avec leur chemin (« 7.1.3 »). Les sous-messages sont
    /// parcourus ; une valeur lisible comme texte est traitée comme texte.
    public static func strings(_ data: Data, path: String = "", depth: Int = 0) -> [(path: String, value: String)] {
        guard let fields = try? parse(data) else { return [] }
        var out: [(String, String)] = []
        for f in fields {
            guard case .bytes(let sub) = f.value else { continue }
            let p = path.isEmpty ? "\(f.number)" : "\(path).\(f.number)"
            if let s = printable(sub) {
                out.append((p, s))
            } else if depth < 6 {
                out += strings(sub, path: p, depth: depth + 1)
            }
        }
        return out
    }

    static func printable(_ data: Data) -> String? {
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return nil }
        let ok = s.unicodeScalars.allSatisfy { sc in
            sc == "\n" || sc == "\t" || !(sc.properties.generalCategory == .control
                || sc.properties.generalCategory == .unassigned)
        }
        return ok ? s : nil
    }
}
