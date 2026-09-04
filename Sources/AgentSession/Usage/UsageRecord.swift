import Foundation

/// One usage-bearing transcript line: the model, the four token counts and when.
struct UsageRecord {
    let id: String?
    let model: String
    let day: String
    let localHour: Int?
    let input: Int, cacheWrite: Int, cacheRead: Int, output: Int

    var tokens: Int { input + cacheWrite + cacheRead + output }
    var cost: Double { ModelPricing.cost(model: model, input: input, cacheWrite: cacheWrite, cacheRead: cacheRead, output: output) }

    /// Nil unless the line is a JSON object carrying `message.usage`.
    init?(line: Data) {
        guard let obj = JSONFile.object(from: line),
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        id = (msg["id"] as? String) ?? (obj["requestId"] as? String)
        model = (msg["model"] as? String).flatMap { $0.isEmpty || $0 == "<synthetic>" ? nil : $0 } ?? "unknown"
        let ts = obj["timestamp"] as? String
        day = ts.map { String($0.prefix(10)) } ?? ""            // ISO8601: the day is its first 10 chars
        localHour = ts.flatMap(UsageRecord.localHour(fromISO:))
        input = usage["input_tokens"] as? Int ?? 0
        cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        output = usage["output_tokens"] as? Int ?? 0
    }

    /// The local hour of an ISO timestamp, from its UTC hour (chars 11–12) and the current offset.
    static func localHour(fromISO ts: String) -> Int? {
        guard ts.count >= 13, let utcHour = Int(ts.dropFirst(11).prefix(2)) else { return nil }
        let offset = TimeZone.current.secondsFromGMT() / 3600
        return ((utcHour + offset) % 24 + 24) % 24
    }
}
