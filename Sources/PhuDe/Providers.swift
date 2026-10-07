import Foundation
import FoundationModels
import Translation

/// Lý do một lần gọi engine thất bại, đã phân loại để Hub biết nên đổi key, đổi engine hay tạm ngưng.
enum Failure: Error {
    case rateLimit(until: Date, daily: Bool, reason: String)   // key hết hạn mức (theo phút hoặc theo ngày)
    case invalidKey(String)                                    // key sai hoặc bị thu hồi
    case unavailable(String)                                   // engine không dùng được (model sai, chưa tải gói ngôn ngữ, chưa bật AI...)
    case transient(String)                                     // lỗi tạm thời: quá tải, mất mạng, quá thời gian
    case refused(String)                                       // nội dung bị từ chối, không phải lỗi của engine

    var message: String {
        switch self {
        case .rateLimit(_, _, let r), .invalidKey(let r), .unavailable(let r), .transient(let r), .refused(let r): return r
        }
    }
}

/// Một câu đã dịch trước đó, làm ngữ cảnh cho câu sau (kèm người nói để giữ xưng hô).
struct ContextLine: Codable, Equatable {
    var speaker: String?
    var source: String
    var vi: String
}

struct ProviderResult {
    var text: String
    var remaining: Int?   // số lượt còn lại theo header của Groq
    var limit: Int?
}

enum Providers {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8   // chờ lâu hơn thì phụ đề đã qua mất, đổi engine nhanh hơn
        return URLSession(configuration: c)
    }()

    // MARK: Prompt

    static func systemPrompt(source: String, target: TargetLanguage = TargetLanguage.find("vi")) -> String {
        if !target.isVietnamese {
            return """
            You translate video game subtitles from \(source) into \(target.english). Keep it natural and spoken.
            - Keep forms of address, politeness level and each character's gender consistent with the previous lines.
            - If the text is only UI (menus, buttons, numbers, item names, logos, key prompts like "[Esc] Back"), return an empty string.
            - Return only the translation, no explanations, no quotes.
            """
        }
        return """
        Bạn là dịch giả phụ đề game. Dịch đoạn \(source) sang tiếng Việt tự nhiên, ngắn gọn, đúng văn nói.
        - Giữ nhất quán đại từ nhân xưng và giới tính nhân vật theo các câu trước.
        - Nếu đoạn chữ chỉ là giao diện (menu, nút bấm, số liệu, tên vật phẩm, logo, hướng dẫn phím như "[Esc] Back"), trả về đúng một chuỗi rỗng.
        - Chỉ trả về bản dịch, không giải thích, không đặt trong dấu ngoặc kép.
        """
    }

    static func userPrompt(_ text: String, context: [(String, String)], fragment: Bool = false,
                           target: TargetLanguage = TargetLanguage.find("vi")) -> String {
        if !target.isVietnamese {
            return englishUserPrompt(text, context: context.map { ContextLine(speaker: nil, source: $0.0, vi: $0.1) }, speaker: nil, fragment: fragment)
        }
        var s = ""
        if !context.isEmpty {
            s += "Các câu trước (gốc → dịch):\n"
            s += context.map { "- \($0.0) → \($0.1)" }.joined(separator: "\n")
            s += "\n\n"
        }
        if fragment {
            s += "(Đây chỉ là một đoạn của câu thoại đang hiện dần, các đoạn trước đã dịch ở trên. Chỉ dịch đúng đoạn này: nối mạch với các đoạn trước, không lặp lại ý đã dịch, không thêm phần chưa hiện. Nếu đoạn chưa kết thúc câu thì không đặt dấu chấm cuối, và nếu là đoạn nối tiếp thì không viết hoa chữ đầu.)\n"
        }
        s += "Câu cần dịch:\n\(text)"
        return s
    }

    /// Lời nhắc "dịch thông minh" (gọn, vì Groq miễn phí giới hạn 8.000 token mỗi phút): phân loại phụ đề + xưng hô + văn phong.
    static func smartSystemPrompt(source: String, filter: Bool, pronouns: Bool, genre: GameGenre, names: Bool = false, usesCodes: Bool = false,
                                  target: TargetLanguage = TargetLanguage.find("vi")) -> String {
        if !target.isVietnamese {
            return englishSmartSystemPrompt(source: source, target: target, filter: filter, pronouns: pronouns, genre: genre, names: names, usesCodes: usesCodes)
        }
        var parts = ["Bạn dịch phụ đề game từ \(source) sang tiếng Việt, tự nhiên, đúng văn nói."]
        if filter {
            parts.append("""
            Chỉ dịch LỜI THOẠI (người hoặc nhân vật đang nói với ai đó). Menu, cài đặt, kho đồ, tên mục, nhãn nút, hướng dẫn phím, số liệu, tiền, thời gian, tên vật phẩm, logo, bản quyền, thông báo hệ thống, nhiệm vụ và mục tiêu thì trả về đúng chữ [BỎ QUA], không viết gì khác; chúng thường là cụm ngắn, mệnh lệnh kiểu nút bấm hoặc có số liệu. Câu có từ như press, back, inventory, menu, level, hold, save mà là người đang nói chuyện vẫn là lời thoại, phải dịch. Không chắc thì dịch.
            Ví dụ: [Esc] Back → [BỎ QUA] | Press E to interact → [BỎ QUA] | Master Volume → [BỎ QUA] | Objective: Reach the bridge → [BỎ QUA] | Hammer of Dawn +3 → [BỎ QUA] | Level up your sword, kid, or you'll never survive. → Nâng cấp thanh kiếm đi nhóc, không thì cậu chẳng sống nổi đâu.
            """)
        }
        if pronouns {
            parts.append("""
            Xưng hô nhất quán (rất quan trọng): dựa vào tên người nói, tuổi, quan hệ, giọng điệu trong các câu trước để chọn cặp xưng hô cho từng cặp người nói và người nghe (như "tớ – cậu", "em – chị", "bà – cháu", "tôi – anh"), giữ nguyên ở các câu sau kể cả khi câu gốc không có đại từ rõ ràng; theo đúng cách đã dùng ở "Các câu trước", chỉ đổi khi quan hệ đổi rõ ràng. she/her thành MỘT từ duy nhất cho mỗi nhân vật theo tuổi và quan hệ (cô ấy, chị ấy, bà ấy...), he/him tương tự; không viết kiểu "cô/bà" hay "anh/chị". Không dùng máy móc "tôi – bạn" cho mọi người. Sis, Granny, Mom... dịch thành chị, bà, mẹ... đúng với người nghe.
            """)
        }
        if names {
            var rule = "Tên riêng (nhân vật, địa danh, tổ chức, quái vật, vật phẩm, chiêu thức) phải GIỮ NGUYÊN như bản gốc, không dịch nghĩa, không phiên âm."
            if usesCodes { rule += " Các mã dạng Xqza, Xqzb là tên riêng đã được mã hoá: giữ nguyên từng mã đúng như vậy và đặt vào đúng chỗ trong câu." }
            parts.append(rule)
        }
        parts.append("Văn phong: \(genre.styleGuide)")
        parts.append("Chỉ trả về bản dịch, không giải thích, không đặt trong dấu ngoặc kép.")
        return parts.joined(separator: "\n\n")
    }

    static func smartUserPrompt(_ text: String, context: [ContextLine], speaker: String?, fragment: Bool,
                                target: TargetLanguage = TargetLanguage.find("vi")) -> String {
        if !target.isVietnamese { return englishUserPrompt(text, context: context, speaker: speaker, fragment: fragment) }
        var s = ""
        if let speaker, !speaker.isEmpty { s += "Người nói: \(speaker)\n" }
        if !context.isEmpty {
            s += "Các câu trước (người nói: gốc → dịch):\n"
            s += context.map { "- \($0.speaker.map { "\($0): " } ?? "")\($0.source) → \($0.vi)" }.joined(separator: "\n")
            s += "\n\n"
        }
        if fragment {
            s += "(Đây chỉ là một đoạn của câu thoại đang hiện dần, các đoạn trước đã dịch ở trên. Chỉ dịch đúng đoạn này: nối mạch với các đoạn trước, không lặp lại ý đã dịch, không thêm phần chưa hiện. Nếu đoạn chưa kết thúc câu thì không đặt dấu chấm cuối, và nếu là đoạn nối tiếp thì không viết hoa chữ đầu.)\n"
        }
        s += "Câu cần dịch:\n\(text)"
        return s
    }

    // MARK: Ngôn ngữ đích khác tiếng Việt (bộ lời nhắc tiếng Anh; tiếng Việt giữ nguyên bộ đã tinh chỉnh ở trên)

    private static func englishSmartSystemPrompt(source: String, target: TargetLanguage, filter: Bool, pronouns: Bool,
                                                 genre: GameGenre, names: Bool, usesCodes: Bool) -> String {
        var parts = ["You translate video game subtitles from \(source) into \(target.english): natural, spoken, faithful to the tone."]
        if filter {
            parts.append("""
            Translate only DIALOGUE (a person or character speaking to someone). Menus, settings, inventory, item names, button labels, key prompts, numbers, money, time, logos, copyright, system notices, quests and objectives: reply with exactly [SKIP] and nothing else; these are usually short phrases, button-like commands or contain numbers. A sentence containing words like press, back, inventory, menu, level, hold, save that is someone talking is still dialogue and must be translated. When unsure, translate.
            Examples: [Esc] Back → [SKIP] | Press E to interact → [SKIP] | Master Volume → [SKIP] | Objective: Reach the bridge → [SKIP] | Hammer of Dawn +3 → [SKIP]
            """)
        }
        if pronouns {
            parts.append("Consistency (very important): from the speaker name, age, relationship and tone in the previous lines, keep each character's forms of address, politeness level (tu/vous, du/Sie, tú/usted, Japanese keigo, Korean speech levels, 你/您...) and gender consistent across lines, even when the source has no explicit pronoun. Follow the \"Previous lines\"; change only when the relationship clearly changes.")
        }
        if names {
            var rule = "Proper nouns (characters, places, organizations, monsters, items, skills) must stay EXACTLY as in the source: not translated, not transliterated."
            if usesCodes { rule += " Tokens like Xqza, Xqzb are encoded names: keep each token exactly as is and place it correctly in the sentence." }
            parts.append(rule)
        }
        parts.append("Style: \(genre.englishHint)")
        parts.append("Return only the translation, no explanations, no quotes.")
        return parts.joined(separator: "\n\n")
    }

    private static func englishUserPrompt(_ text: String, context: [ContextLine], speaker: String?, fragment: Bool) -> String {
        var s = ""
        if let speaker, !speaker.isEmpty { s += "Speaker: \(speaker)\n" }
        if !context.isEmpty {
            s += "Previous lines (speaker: source → translation):\n"
            s += context.map { "- \($0.speaker.map { "\($0): " } ?? "")\($0.source) → \($0.vi)" }.joined(separator: "\n")
            s += "\n\n"
        }
        if fragment {
            s += "(This is only a fragment of a line still appearing on screen; earlier fragments were translated above. Translate only this fragment, continuing smoothly, without repeating or adding anything. If the sentence is not finished, do not end it with a period, and do not capitalize a continuation.)\n"
        }
        s += "Line to translate:\n\(text)"
        return s
    }

    static func clean(_ s: String) -> String {
        var t = s
        // Một số model (Qwen...) có thể chèn phần suy nghĩ trong <think>…</think> trước câu trả lời.
        while let open = t.range(of: "<think>") {
            if let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) { t.removeSubrange(open.lowerBound..<close.upperBound) }
            else { t.removeSubrange(open.lowerBound..<t.endIndex) }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for q in ["\"", "“", "”"] where t.hasPrefix(q) && t.hasSuffix(q) && t.count > 1 {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Gemini

    /// `onPartial`: nhận bản dịch theo luồng (chữ dài dần) để hiện và đọc câu đầu sớm hơn.
    static func gemini(key: String, model: String, system: String, user: String, maxTokens: Int = 256,
                       onPartial: (@MainActor (String) -> Void)? = nil) async throws -> ProviderResult {
        let method = onPartial == nil ? "generateContent" : "streamGenerateContent?alt=sse"
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(method)") else {
            throw Failure.unavailable(L("Tên model Gemini không hợp lệ.", "Invalid Gemini model name."))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": maxTokens],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, http: HTTPURLResponse
        if let onPartial {
            var safety = false
            let r = try await streamSSE(req, name: "Gemini", onPartial: onPartial) { json in
                if (json["promptFeedback"] as? [String: Any])?["blockReason"] != nil { safety = true }
                let cand = (json["candidates"] as? [[String: Any]])?.first
                if (cand?["finishReason"] as? String) == "SAFETY" { safety = true }
                let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
                return (parts ?? []).filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            }
            if r.http.statusCode == 200 {
                if safety { throw Failure.refused(L("Gemini chặn nội dung (bộ lọc an toàn).", "Gemini blocked the content (safety filter).")) }
                return ProviderResult(text: r.text, remaining: nil, limit: nil)
            }
            (data, http) = (r.errorData, r.http)
        } else {
            (data, http) = try await send(req, name: "Gemini")
        }
        let status = http.statusCode
        if status == 200 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let block = (json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
                throw Failure.refused(L("Gemini chặn nội dung (\(block)).", "Gemini blocked the content (\(block))."))
            }
            let cand = (json?["candidates"] as? [[String: Any]])?.first
            if (cand?["finishReason"] as? String) == "SAFETY" { throw Failure.refused(L("Gemini chặn nội dung (bộ lọc an toàn).", "Gemini blocked the content (safety filter).")) }
            let parts = (cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            // Có thể lẫn phần "thought"; chỉ lấy phần trả lời.
            let text = (parts ?? []).filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            return ProviderResult(text: text, remaining: nil, limit: nil)
        }
        let message = errorMessage(data)
        switch status {
        case 429:
            let info = parseGemini429(data)
            if info.daily {
                throw Failure.rateLimit(until: nextMidnightPacific(), daily: true,
                                        reason: L("Hết hạn mức trong ngày (Google đặt lại lúc 0 giờ giờ Thái Bình Dương)", "Daily quota used up (Google resets it at midnight Pacific Time)"))
            }
            throw Failure.rateLimit(until: Date().addingTimeInterval(info.retry ?? 60), daily: false,
                                    reason: L("Vượt giới hạn số lượt mỗi phút", "Per-minute request limit exceeded"))
        case 400 where message.contains("API key not valid") || message.contains("API_KEY_INVALID"):
            throw Failure.invalidKey(L("Key Gemini không hợp lệ", "Invalid Gemini key"))
        case 401, 403:
            throw Failure.invalidKey(L("Key Gemini bị từ chối (HTTP \(status)): \(message.prefix(120))", "Gemini key rejected (HTTP \(status)): \(message.prefix(120))"))
        case 400, 404:
            throw Failure.unavailable(L("Model Gemini \"\(model)\" không dùng được: \(message.prefix(120))", "Gemini model \"\(model)\" isn't available: \(message.prefix(120))"))
        default:
            throw Failure.transient(L("Gemini lỗi HTTP \(status): \(message.prefix(120))", "Gemini HTTP error \(status): \(message.prefix(120))"))
        }
    }

    private static func parseGemini429(_ data: Data) -> (daily: Bool, retry: TimeInterval?) {
        var daily = false
        var retry: TimeInterval?
        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        for d in (err?["details"] as? [[String: Any]]) ?? [] {
            let type = (d["@type"] as? String) ?? ""
            if type.hasSuffix("QuotaFailure") {
                for v in (d["violations"] as? [[String: Any]]) ?? [] {
                    let id = (v["quotaId"] as? String) ?? ""
                    if id.contains("PerDay") { daily = true }
                }
            }
            if type.hasSuffix("RetryInfo"), let s = d["retryDelay"] as? String {
                retry = Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "s")))
            }
        }
        let msg = ((err?["message"] as? String) ?? "").lowercased()
        if !daily && (msg.contains("per day") || msg.contains("daily")) { daily = true }
        return (daily, retry)
    }

    /// Google đặt lại hạn mức ngày của gói miễn phí vào nửa đêm theo giờ Thái Bình Dương.
    static func nextMidnightPacific() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(3600)
    }

    // MARK: Dịch vụ kiểu OpenAI (Groq, Cerebras, Mistral, OpenRouter, dịch vụ tự thêm)

    static func groq(key: String, model: String, system: String, user: String, maxTokens: Int = 256,
                     onPartial: (@MainActor (String) -> Void)? = nil) async throws -> ProviderResult {
        try await openAI(.groq, key: key, model: model, system: system, user: user, maxTokens: maxTokens, onPartial: onPartial)
    }

    /// `modern`: dùng tham số kiểu mới của OpenAI (max_completion_tokens, không đặt temperature) cho các model từ chối kiểu cũ.
    static func openAI(_ engine: EngineKind, key: String, model: String, system: String, user: String, maxTokens: Int = 256,
                       modern: Bool = false, onPartial: (@MainActor (String) -> Void)? = nil) async throws -> ProviderResult {
        let name = engine.title
        guard !model.isEmpty else { throw Failure.unavailable(L("Chưa đặt tên model cho \(name).", "No model name set for \(name).")) }
        guard let url = URL(string: engine.baseURL + "/chat/completions"), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw Failure.unavailable(L("Địa chỉ API của \(name) không hợp lệ (cần bắt đầu bằng https://).", "The API address for \(name) isn't valid (it must start with https://)."))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if engine == .openRouter { req.setValue("OverSub", forHTTPHeaderField: "X-Title") }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        var tokens = maxTokens
        let lower = model.lowercased()
        if lower.contains("gpt-oss") {
            // Model suy luận: nếu không giới hạn, phần "suy nghĩ" ăn hết số token và câu dịch bị rỗng.
            body["reasoning_effort"] = "low"
            tokens = max(1024, maxTokens)
        } else if lower.contains("qwen") || lower.contains("reason") || lower.contains("think") {
            tokens = max(1024, maxTokens)   // có thể chèn khối <think> trước câu trả lời
        }
        if modern {
            body["max_completion_tokens"] = max(1024, tokens)
        } else {
            body["temperature"] = 0.3
            body["max_tokens"] = tokens
        }
        if onPartial != nil { body["stream"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        func quota(_ http: HTTPURLResponse) -> (Int?, Int?) {
            // Groq: số lượt trong ngày; Cerebras: có hậu tố -day.
            let rem = Int(http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests-day") ?? "")
                ?? Int(http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests") ?? "")
            let lim = Int(http.value(forHTTPHeaderField: "x-ratelimit-limit-requests-day") ?? "")
                ?? Int(http.value(forHTTPHeaderField: "x-ratelimit-limit-requests") ?? "")
            return engine == .groq || engine == .cerebras ? (rem, lim) : (nil, nil)
        }

        let data: Data, http: HTTPURLResponse
        if let onPartial {
            let r = try await streamSSE(req, name: name, onPartial: onPartial) { json in
                let choices = json["choices"] as? [[String: Any]]
                return (choices?.first?["delta"] as? [String: Any])?["content"] as? String
            }
            if r.http.statusCode == 200 {
                let q = quota(r.http)
                return ProviderResult(text: r.text, remaining: q.0, limit: q.1)
            }
            (data, http) = (r.errorData, r.http)
        } else {
            (data, http) = try await send(req, name: name)
        }
        let status = http.statusCode
        let message = errorMessage(data)
        if status == 200 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let text = (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            // OpenRouter có khi trả HTTP 200 kèm lỗi của nhà cung cấp phía sau.
            if text.isEmpty, json?["error"] != nil {
                throw Failure.transient(L("\(name) báo lỗi: \(message.prefix(120))", "\(name) reported an error: \(message.prefix(120))"))
            }
            let q = quota(http)
            return ProviderResult(text: text, remaining: q.0, limit: q.1)
        }
        let low = message.lowercased()
        switch status {
        case 429:
            let daily = low.contains("per day") || low.contains("per-day") || low.contains("daily") || low.contains("tokens per month")
            var wait = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? parseTryAgain(message)
            if wait == nil, daily { wait = 3600 }
            // Mistral miễn phí giới hạn một lượt mỗi giây: chỉ cần nghỉ rất ngắn.
            let pause = wait ?? (engine == .mistral ? 3 : 60)
            throw Failure.rateLimit(until: Date().addingTimeInterval(pause), daily: daily,
                                    reason: daily ? L("Hết hạn mức trong ngày của \(name)", "\(name) daily quota used up") : L("Vượt giới hạn số lượt hoặc token mỗi phút", "Per-minute request or token limit exceeded"))
        case 402:
            throw Failure.rateLimit(until: Date().addingTimeInterval(3600), daily: true,
                                    reason: L("Tài khoản \(name) hết tín dụng", "The \(name) account is out of credits"))
        case 401, 400 where status == 401 || low.contains("api key"):   // xAI báo key sai bằng HTTP 400
            throw Failure.invalidKey(L("Key \(name) không hợp lệ", "Invalid \(name) key"))
        case 403:
            throw Failure.invalidKey(L("Key \(name) bị từ chối (HTTP 403): \(message.prefix(120))", "\(name) key rejected (HTTP 403): \(message.prefix(120))"))
        case 400 where !modern && (low.contains("max_completion_tokens") || low.contains("temperature")):
            return try await openAI(engine, key: key, model: model, system: system, user: user, maxTokens: maxTokens, modern: true, onPartial: onPartial)
        case 400, 404, 422:
            throw Failure.unavailable(L("Model \(name) \"\(model)\" không dùng được: \(message.prefix(120))", "\(name) model \"\(model)\" isn't available: \(message.prefix(120))"))
        default:
            throw Failure.transient(L("\(name) lỗi HTTP \(status): \(message.prefix(120))", "\(name) HTTP error \(status): \(message.prefix(120))"))
        }
    }

    /// Đọc "Please try again in 7m54.2s" trong thông báo lỗi của Groq.
    private static func parseTryAgain(_ message: String) -> TimeInterval? {
        guard let r = message.range(of: "try again in ") else { return nil }
        let rest = message[r.upperBound...].prefix(24)
        var total = 0.0
        var number = ""
        for ch in rest {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let v = Double(number) else { break }
            number = ""
            switch ch {
            case "h": total += v * 3600
            case "m": total += v * 60
            case "s": total += v
            default: return total > 0 ? total : nil
            }
        }
        return total > 0 ? total : nil
    }

    // MARK: Danh sách model

    /// Hỏi nhà cung cấp tài khoản này đang dùng được những model nào. Gọi được nghĩa là key hợp lệ.
    static func listModels(_ engine: EngineKind, key: String) async throws -> [String] {
        var req: URLRequest
        switch engine {
        case .groq, .cerebras, .mistral, .openRouter, .custom:
            guard let url = URL(string: engine.baseURL + "/models") else {
                throw Failure.unavailable(L("Địa chỉ API của \(engine.title) không hợp lệ.", "The API address for \(engine.title) isn't valid."))
            }
            req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            throw Failure.unavailable(L("Dịch vụ này không có danh sách model.", "This service has no model list."))
        }
        let (data, http) = try await send(req, name: engine.title)
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401, 403: throw Failure.invalidKey(L("Key \(engine.title) bị từ chối (HTTP \(http.statusCode)): \(errorMessage(data).prefix(120))", "\(engine.title) key rejected (HTTP \(http.statusCode)): \(errorMessage(data).prefix(120))"))
            case 400 where errorMessage(data).contains("API key not valid"): throw Failure.invalidKey(L("Key Gemini không hợp lệ", "Invalid Gemini key"))
            case 429: throw Failure.rateLimit(until: Date().addingTimeInterval(60), daily: false, reason: L("Vượt giới hạn số lượt mỗi phút", "Per-minute request limit exceeded"))
            default: throw Failure.transient(L("\(engine.title) lỗi HTTP \(http.statusCode): \(errorMessage(data).prefix(120))", "\(engine.title) HTTP error \(http.statusCode): \(errorMessage(data).prefix(120))"))
            }
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if engine.isOpenAIStyle {
            return ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        }
        return ((json?["models"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let name = m["name"] as? String,
                  (m["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
    }

    /// Chọn model dịch văn bản phù hợp nhất trong danh sách tài khoản dùng được.
    static func pickModel(_ engine: EngineKind, from models: [String]) -> String? {
        let preferred: [String]
        let banned: [String]
        let mustContain: String?
        switch engine {
        case .groq:
            banned = ["whisper", "tts", "guard", "safeguard", "orpheus", "playai", "embed", "distil"]
            mustContain = nil
            // Thử thực tế trên câu thoại game: Qwen nhanh nhất (~250 ms) và dịch tự nhiên hơn gpt-oss-20b (~600 ms, hay dịch sai tên).
            if models.contains("llama-3.3-70b-versatile") { return "llama-3.3-70b-versatile" }
            if let qwen = models.filter({ $0.hasPrefix("qwen/") && !banned.contains(where: $0.lowercased().contains) }).sorted().last { return qwen }
            preferred = ["llama-3.1-8b-instant", "openai/gpt-oss-20b", "openai/gpt-oss-120b"]
        case .cerebras:
            // Cerebras đổi danh mục model thường xuyên: ưu tiên model không suy luận, rồi tới gpt-oss (đặt được mức suy luận thấp).
            preferred = ["llama-3.3-70b", "llama-4-maverick", "gpt-oss-120b"]
            banned = ["embed", "guard", "whisper", "safety"]
            mustContain = nil
        case .mistral:
            preferred = ["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest"]
            banned = ["embed", "moderation", "ocr", "codestral", "voxtral", "pixtral", "devstral", "transcribe", "tts"]
            mustContain = nil
        case .openRouter:
            // Chỉ tự chọn model miễn phí; model trả phí thì người dùng tự nhập tên.
            let free = models.filter { $0.hasSuffix(":free") }
            let skip = ["safety", "guard", "code", "nano", "reasoning", "omni", "preview", "note"]
            let wanted = ["gemma-4-31b", "gemma-4", "gemma", "llama-3.3-70b", "llama", "mistral", "qwen", "nemotron-3-super"]
            for w in wanted {
                if let hit = free.first(where: { $0.contains(w) && !skip.contains(where: $0.contains) }) { return hit }
            }
            return free.first { id in !skip.contains(where: id.contains) }
        case .custom:
            preferred = ["gpt-5-mini", "gpt-4.1-mini", "gpt-4o-mini", "deepseek-chat", "grok-4-fast-non-reasoning", "grok-4-fast"]
            banned = ["embed", "whisper", "tts", "audio", "image", "realtime", "moderation", "dall-e", "sora", "transcribe", "search", "codex"]
            mustContain = nil
        case .gemini:
            preferred = ["gemini-flash-lite-latest", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-flash-latest",
                         "gemini-3.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-flash"]
            banned = ["image", "tts", "live", "embedding", "audio", "robotics", "computer", "vision"]
            mustContain = "flash"
        default:
            return nil
        }
        if let hit = preferred.first(where: models.contains) { return hit }
        return models.first { id in
            let l = id.lowercased()
            return !banned.contains(where: l.contains) && (mustContain.map(l.contains) ?? true)
        }
    }

    // MARK: Apple

    static func appleAI(system: String, user: String, targetCode: String = "vi") async throws -> String {
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability {
            throw Failure.unavailable(L("Apple Intelligence không dùng được: \(reason)", "Apple Intelligence isn't available: \(reason)"))
        }
        if !model.supportsLocale(Locale(identifier: targetCode)) {
            throw Failure.unavailable(L("Apple Intelligence chưa hỗ trợ ngôn ngữ đích này trên máy.", "Apple Intelligence doesn't support this target language on this Mac yet."))
        }
        do {
            return try await LanguageModelSession(instructions: system).respond(to: user).content
        } catch {
            // Thực tế gặp: LanguageModelError "May contain unsafe content" với cả chữ giao diện vô hại như "[Esc] Back".
            let d = (String(describing: error) + " " + error.localizedDescription).lowercased()
            if ["guardrail", "unsafe", "cannot process", "refus"].contains(where: d.contains) {
                throw Failure.refused(L("Apple Intelligence từ chối nội dung này.", "Apple Intelligence refused this content."))
            }
            throw Failure.transient(L("Apple Intelligence lỗi: \(error.localizedDescription)", "Apple Intelligence error: \(error.localizedDescription)"))
        }
    }

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var appleSessions: [String: TranslationSession] = [:]

    private static func cachedSession(for key: String, src: Locale.Language, dst: Locale.Language) -> TranslationSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let s = appleSessions[key] { return s }
        let s = TranslationSession(installedSource: src, target: dst)
        appleSessions[key] = s
        return s
    }

    static func appleTranslate(_ text: String, source: String, target: String = "vi") async throws -> String {
        let src = Locale.Language(identifier: source)
        let dst = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: src, to: dst) {
        case .installed: break
        case .supported:
            throw Failure.unavailable(L("Chưa tải gói dịch \(source) → \(target). Mở System Settings → General → Language & Region → Translation Languages.", "The \(source) → \(target) translation pack isn't downloaded. Open System Settings → General → Language & Region → Translation Languages."))
        default:
            throw Failure.unavailable(L("Dịch máy Apple không hỗ trợ cặp ngôn ngữ này.", "Apple Translation doesn't support this language pair."))
        }
        let session = cachedSession(for: source + ">" + target, src: src, dst: dst)
        do {
            return try await session.translate(text).targetText
        } catch {
            throw Failure.transient(L("Dịch máy Apple lỗi: \(error.localizedDescription)", "Apple Translation error: \(error.localizedDescription)"))
        }
    }

    /// Chạy thử một câu ngắn lúc mở app: lần gọi đầu của hai engine Apple mất 2 đến 4 giây để khởi động.
    static func warmUp(source: String, target: String = "vi") async {
        _ = try? await appleTranslate("Hello", source: source, target: target)
        _ = try? await appleAI(system: "Translate.", user: "Hello", targetCode: target)
    }

    // MARK: HTTP

    private static func send(_ req: URLRequest, name: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw Failure.transient(L("\(name) trả về phản hồi lạ.", "\(name) returned an unexpected response.")) }
            return (data, http)
        } catch let f as Failure {
            throw f
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()   // bị huỷ vì engine khác đã trả lời trước: không tính là lỗi của engine
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw Failure.transient(L("\(name) quá thời gian chờ.", "\(name) timed out."))
        } catch let e as URLError {
            throw Failure.transient(L("\(name) mất kết nối: \(e.localizedDescription)", "\(name) lost connection: \(e.localizedDescription)"))
        } catch {
            throw Failure.transient("\(name): \(error.localizedDescription)")
        }
    }

    /// Gửi yêu cầu theo luồng (server-sent events): mỗi dòng "data:" là một mảnh JSON, `extract` lấy phần chữ của mảnh đó.
    /// Trả về chữ đã ghép khi thành công, hoặc nội dung lỗi để xử lý như yêu cầu thường.
    /// `onPartial` luôn chạy trên luồng chính (nó cập nhật giao diện, tạo cửa sổ phụ đề); gọi từ luồng nền sẽ làm app bị huỷ.
    private static func streamSSE(_ req: URLRequest, name: String, onPartial: @MainActor (String) -> Void,
                                  extract: ([String: Any]) -> String?) async throws -> (http: HTTPURLResponse, text: String, errorData: Data) {
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard let http = resp as? HTTPURLResponse else { throw Failure.transient(L("\(name) trả về phản hồi lạ.", "\(name) returned an unexpected response.")) }
            guard http.statusCode == 200 else {
                var data = Data()
                for try await b in bytes { data.append(b); if data.count > 20_000 { break } }
                return (http, "", data)
            }
            var text = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", let d = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let piece = extract(json), !piece.isEmpty {
                    text += piece
                    await onPartial(text)
                }
            }
            return (http, text, Data())
        } catch let f as Failure {
            throw f
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError where e.code == .timedOut {
            throw Failure.transient(L("\(name) quá thời gian chờ.", "\(name) timed out."))
        } catch let e as URLError {
            throw Failure.transient(L("\(name) mất kết nối: \(e.localizedDescription)", "\(name) lost connection: \(e.localizedDescription)"))
        } catch {
            throw Failure.transient("\(name): \(error.localizedDescription)")
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let e = json?["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
