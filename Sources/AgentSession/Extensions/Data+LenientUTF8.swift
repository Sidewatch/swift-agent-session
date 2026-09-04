import Foundation

extension Data {
    /// The bytes as UTF-8, discarding a truncated final character rather than failing.
    ///
    /// A fixed-length head read can land inside a multi-byte sequence, and strict decoding then
    /// returns nil for the WHOLE buffer — losing a `cwd` that sits on line 1 and making the
    /// session permanently invisible. A UTF-8 sequence is at most 4 bytes, so at most 3
    /// trailing bytes can be partial.
    var lenientUTF8String: String? {
        if let text = String(data: self, encoding: .utf8) { return text }
        for drop in 1...3 where count > drop {
            if let text = String(data: dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }
}
