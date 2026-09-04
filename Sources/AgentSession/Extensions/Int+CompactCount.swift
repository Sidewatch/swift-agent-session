import Foundation

extension Int {
    /// A token or byte count at a glance: `999`, `1.5K`, `2.5M`, `3.0B`.
    public var compactCount: String {
        let x = Double(self)
        if x >= 1e9 { return String(format: "%.1fB", x / 1e9) }
        if x >= 1e6 { return String(format: "%.1fM", x / 1e6) }
        if x >= 1e3 { return String(format: "%.1fK", x / 1e3) }
        return "\(self)"
    }
}
