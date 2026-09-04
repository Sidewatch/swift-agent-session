import Foundation

extension Date {
    /// A date from epoch **milliseconds** — what OpenCode records. Treating them as seconds
    /// would date every row to 1970.
    init(epochMilliseconds: Double) { self.init(timeIntervalSince1970: epochMilliseconds / 1000) }
}
