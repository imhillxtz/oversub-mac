import Foundation

/// Gemini TTS qua Interactions API, nhận âm thanh theo luồng (PCM 16-bit, 24 kHz, mono).
/// Ghi số liệu từng lượt gọi để người dùng tự cân nhắc dùng key miễn phí hay trả phí.
@MainActor
final class GeminiTTS: ObservableObject {
    struct Sample: Codable, Identifiable {
        var id = UUID()
        var date = Date()
        var ok: Bool
        var firstAudio: Double?     // giây tới khi có âm thanh đầu tiên
        var total: Double           // giây tới khi xong
        var audioSeconds: Double
        var outputTokens: Int?
        var model: String
        var error: String?
    }

    enum TTSError: Error {
        case noKey
        case rateLimited(String)
        case failed(String)
        var message: String {
            switch self {
            case .noKey: return L("Chưa có key Gemini dùng được", "No usable Gemini API key")
            case .rateLimited(let m), .failed(let m): return m
            }
        }
    }

    static let models: [(id: String, title: String, outputPrice: Double, outputPrice2027: Double)] = [
        ("gemini-3.8-flash-lite-tts", "Flash-Lite (rẻ, nhanh hơn)", 6, 12),
        ("gemini-3.8-flash-tts", "Flash (hay hơn)", 9, 18),
    ]
    static let inputPrice = 0.5          // USD cho 1 triệu token chữ vào (tới hết 2026)
    static let sampleRate = 24000.0

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var callsToday = 0
    @Published private(set) var rateLimitedToday = 0
    @Published private(set) var day = ""
    @Published private(set) var cooldown: [UUID: Date] = [:]
    @Published private(set) var lastError: String?

    private let hub: TranslationHub
    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var cursor = 0

    init(hub: TranslationHub, settings: AppSettings) {
        self.hub = hub
        self.settings = settings
        if let data = defaults.data(forKey: "ttsSamples"), let s = try? JSONDecoder().decode([Sample].self, from: data) { samples = s }
        day = defaults.string(forKey: "ttsDay") ?? ""
        callsToday = defaults.integer(forKey: "ttsCalls")
        rateLimitedToday = defaults.integer(forKey: "ttsLimited")
        rollDay()
    }

    // MARK: Số liệu

    private func today() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    private func rollDay() {
        let t = today()
        if day != t { day = t; callsToday = 0; rateLimitedToday = 0; persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(samples.suffix(60))) { defaults.set(data, forKey: "ttsSamples") }
        defaults.set(day, forKey: "ttsDay")
        defaults.set(callsToday, forKey: "ttsCalls")
        defaults.set(rateLimitedToday, forKey: "ttsLimited")
    }

    private func record(_ s: Sample) {
        rollDay()
        samples.append(s)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        callsToday += 1
        if !s.ok { lastError = s.error }
        persist()
    }

    var okSamples: [Sample] { samples.filter(\.ok) }
    var medianFirstAudio: Double? { median(okSamples.compactMap(\.firstAudio)) }
    var successRate: Double? { samples.isEmpty ? nil : Double(samples.filter(\.ok).count) / Double(samples.count) }
    /// Token âm thanh trên mỗi câu, đo thực tế; chưa có số liệu thì dùng số đo khi phát triển (khoảng 110–200 token một câu).
    var tokensPerLine: Double {
        let t = okSamples.compactMap(\.outputTokens)
        return t.isEmpty ? 150 : Double(t.reduce(0, +)) / Double(t.count)
    }

    private func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); return s[s.count / 2]
    }

    /// Chi phí ước tính cho mỗi câu (USD) với key trả phí, theo giá hiện tại của model.
    func costPerLine(model: String) -> Double {
        let m = Self.models.first { $0.id == model } ?? Self.models[0]
        let out = Date() < Self.priceChange ? m.outputPrice : m.outputPrice2027
        let input = (Date() < Self.priceChange ? Self.inputPrice : Self.inputPrice * 2) * 30 / 1_000_000   // ~30 token chữ mỗi câu
        return tokensPerLine * out / 1_000_000 + input
    }
    static let priceChange: Date = {
        var c = DateComponents(); c.year = 2027; c.month = 1; c.day = 1
        return Calendar(identifier: .gregorian).date(from: c) ?? Date.distantFuture
    }()

    var usableKeyCount: Int { hub.keys(for: .gemini).filter { (cooldown[$0.id] ?? .distantPast) < Date() }.count }

    // MARK: Gọi API

    /// Đọc một câu, trả âm thanh theo từng mảnh PCM 16-bit. Key hết lượt thì thử key kế tiếp trước khi có âm thanh.
    func stream(text: String, voice: String, style: String?) -> AsyncThrowingStream<Data, Error> {
        let model = settings.geminiTTSModel
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let keys = self.orderedKeys()
                guard !keys.isEmpty else { continuation.finish(throwing: TTSError.noKey); return }
                var lastErr: TTSError = .noKey
                for key in keys {
                    let t0 = Date()
                    var first: Double?
                    var bytes = 0
                    var tokens: Int?
                    do {
                        try await self.request(key: key.secret, model: model, text: text, voice: voice, style: style) { chunk in
                            if first == nil { first = Date().timeIntervalSince(t0) }
                            bytes += chunk.count
                            continuation.yield(chunk)
                        } usage: { tokens = $0 }
                        self.record(Sample(ok: true, firstAudio: first, total: Date().timeIntervalSince(t0),
                                           audioSeconds: Double(bytes) / 2 / Self.sampleRate, outputTokens: tokens, model: model))
                        continuation.finish()
                        return
                    } catch let e as TTSError {
                        lastErr = e
                        self.record(Sample(ok: false, firstAudio: first, total: Date().timeIntervalSince(t0), audioSeconds: 0,
                                           outputTokens: nil, model: model, error: e.message))
                        if case .rateLimited = e { self.rateLimitedToday += 1; self.persist() }
                        if bytes > 0 { break }   // đã phát một phần thì không đọc lại bằng key khác
                    } catch {
                        lastErr = .failed(error.localizedDescription)
                        if Task.isCancelled { break }
                    }
                }
                continuation.finish(throwing: lastErr)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func orderedKeys() -> [KeyEntry] {
        let now = Date()
        let list = hub.keys(for: .gemini).filter { (cooldown[$0.id] ?? .distantPast) < now }
        guard !list.isEmpty else { return [] }
        let start = cursor % list.count
        cursor += 1
        return Array(list[start...] + list[..<start])
    }

    private func request(key: String, model: String, text: String, voice: String, style: String?,
                         onAudio: (Data) -> Void, usage: (Int) -> Void) async throws {
        var content: [String: Any] = ["type": "text", "text": text]
        if let style, !style.isEmpty { content["annotations"] = [["type": "speech_metadata", "style": style]] }
        let body: [String: Any] = [
            "model": model, "stream": true,
            "input": [["type": "user_input", "content": [content]]],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": voice]]],
        ]
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (stream, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await b in stream { data.append(b); if data.count > 20_000 { break } }
            throw classify(status: status, data: data, key: key)
        }
        for try await line in stream.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "audio",
               let b64 = delta["data"] as? String, let pcm = Data(base64Encoded: b64) {
                onAudio(pcm.prefix(4) == Data("RIFF".utf8) ? pcm.dropFirst(44) : pcm)
            }
            if let inter = obj["interaction"] as? [String: Any], let u = inter["usage"] as? [String: Any],
               let out = u["total_output_tokens"] as? Int {
                usage(out)
            }
            if let err = obj["error"] as? [String: Any] {
                throw TTSError.failed((err["message"] as? String) ?? L("Gemini TTS báo lỗi", "Gemini TTS returned an error"))
            }
        }
    }

    private func classify(status: Int, data: Data, key: String) -> TTSError {
        let text = String(data: data, encoding: .utf8) ?? ""
        let entry = hub.keys(for: .gemini).first { $0.secret == key }
        switch status {
        case 429:
            let daily = text.contains("PerDay")
            var until = Providers.nextMidnightPacific()
            if !daily {
                var secs = 60.0
                if let r = text.range(of: #""retryDelay":\s*"(\d+)"#, options: .regularExpression) {
                    secs = Double(text[r].filter(\.isNumber)) ?? 60
                }
                until = Date().addingTimeInterval(secs)
            }
            if let entry { cooldown[entry.id] = until }
            return .rateLimited(daily ? L("Key hết lượt Gemini TTS trong ngày", "API key is out of Gemini TTS quota for today") : L("Gọi Gemini TTS quá nhanh, chờ \(Int(until.timeIntervalSinceNow)) giây", "Too many Gemini TTS requests, wait \(Int(until.timeIntervalSinceNow)) seconds"))
        case 400 where text.contains("API key not valid"), 401, 403:
            if let entry { cooldown[entry.id] = Date().addingTimeInterval(86_400) }
            return .failed(L("Key bị từ chối (HTTP \(status))", "API key rejected (HTTP \(status))"))
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(status)"
            return .failed(L("Gemini TTS lỗi: \(msg.prefix(140))", "Gemini TTS error: \(msg.prefix(140))"))
        }
    }
}
