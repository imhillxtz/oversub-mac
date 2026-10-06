import Foundation

/// Một thuật ngữ cần giữ nguyên hoặc luôn dịch theo cách cố định (tên nhân vật, địa danh, quái vật, chiêu thức...).
struct GlossaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var term: String
    var translation: String?   // nil hoặc rỗng: giữ nguyên như bản gốc

    var keepsAsIs: Bool { translation?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }
}

/// Bảo vệ thuật ngữ bằng mã tạm: thay thuật ngữ bằng một mã giả như tên riêng (Xqza, Xqzb...) trước khi dịch rồi thay lại sau.
/// Làm được với cả máy dịch không nhận lệnh; đo thực tế giữ đủ 20/20 tên trên Gemini, Groq và Dịch máy Apple.
enum Glossary {
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")

    struct Protected {
        var text: String
        var map: [(code: String, replacement: String)]
        var isEmpty: Bool { map.isEmpty }
    }

    private static func regex(for term: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: term.trimmingCharacters(in: .whitespaces))
        // Nguyên từ, không phân biệt hoa thường: "CATAVAN!" vẫn nhận ra "Catavan".
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    /// Thuật ngữ nào có mặt trong câu này (để chỉ đưa các mục liên quan vào lời nhắc, tiết kiệm token).
    static func matches(in text: String, entries: [GlossaryEntry]) -> [GlossaryEntry] {
        entries.filter { e in
            guard !e.term.trimmingCharacters(in: .whitespaces).isEmpty, let rx = regex(for: e.term) else { return false }
            return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    static func protect(_ text: String, entries: [GlossaryEntry]) -> Protected {
        var out = text
        var map: [(String, String)] = []
        // Cụm dài thay trước để "Stormveil Castle" không bị cắt thành "Stormveil" rồi "Castle".
        for e in matches(in: text, entries: entries).sorted(by: { $0.term.count > $1.term.count }).prefix(letters.count) {
            guard let rx = regex(for: e.term) else { continue }
            let code = "Xqz" + String(letters[map.count])
            // Giữ nguyên: trả lại đúng chữ như trong câu gốc (kể cả chữ hoa); có bản dịch cố định: dùng bản dịch đó.
            let range = NSRange(out.startIndex..., in: out)
            let original = rx.firstMatch(in: out, range: range).flatMap { Range($0.range, in: out).map { String(out[$0]) } } ?? e.term
            out = rx.stringByReplacingMatches(in: out, range: range, withTemplate: code)
            map.append((code, e.keepsAsIs ? original : e.translation!.trimmingCharacters(in: .whitespaces)))
        }
        return Protected(text: out, map: map)
    }

    /// Thay mã về lại. Trả về số mã bị mất (máy dịch làm hỏng hoặc bỏ mất).
    static func restore(_ text: String, _ p: Protected) -> (text: String, lost: Int) {
        var out = text, lost = 0
        for (code, replacement) in p.map {
            if out.contains(code) { out = out.replacingOccurrences(of: code, with: replacement) } else { lost += 1 }
        }
        return (out, lost)
    }

    // MARK: Gợi ý tên riêng từ câu đang hiện

    private static let leadingWords: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its",
                                                     "and", "but", "or", "so", "if", "when", "while", "then", "now", "oh", "well", "yes", "no", "hey", "please"]
    private static let connectors: Set<String> = ["of", "the", "de", "von", "van", "la", "le", "du"]
    private static let notNames: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                                                 "sunday", "january", "february", "march", "april", "may", "june", "july", "august", "september",
                                                 "october", "november", "december", "mr", "mrs", "ms", "dr", "ok", "okay"]

    /// Các cụm viết hoa nhiều khả năng là tên riêng: viết hoa giữa câu, hoặc cụm từ hai chữ viết hoa trở lên (chữ đầu câu thường chỉ viết hoa theo quy tắc).
    static func candidates(in text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func clean(_ w: String) -> String {
            var t = w.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-")))
            for suffix in ["'s", "’s"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
            return t
        }
        func isCap(_ w: String) -> Bool {
            let t = clean(w)
            guard let f = t.first, f.isUppercase, t.count >= 2 else { return false }
            return !notNames.contains(t.lowercased())
        }
        func endsSentence(_ w: String) -> Bool { w.last.map { ".!?…。！？".contains($0) } ?? false }
        func endsClause(_ w: String) -> Bool { w.last.map { ".!?…。！？,;:，；：".contains($0) } ?? false }

        var result: [String] = []
        var i = 0
        var sentenceStart = true
        while i < words.count {
            guard isCap(words[i]) else {
                sentenceStart = endsSentence(words[i]); i += 1; continue
            }
            // Gom cụm các chữ viết hoa liên tiếp, cho phép "of", "the"... xen giữa; dấu phẩy, dấu chấm cắt cụm.
            var run = [clean(words[i])]
            var j = i + 1
            var ended = endsClause(words[i])
            while j < words.count, !ended {
                if isCap(words[j]) {
                    run.append(clean(words[j])); ended = endsClause(words[j]); j += 1
                } else if connectors.contains(clean(words[j]).lowercased()) {
                    // "of the Wind": cho phép tới hai từ nối liên tiếp, miễn ngay sau là chữ viết hoa
                    var k = j
                    while k < words.count, connectors.contains(clean(words[k]).lowercased()), !endsClause(words[k]) { k += 1 }
                    guard k < words.count, isCap(words[k]), k - j <= 2 else { break }
                    run.append(contentsOf: words[j..<k].map(clean)); j = k
                } else { break }
            }
            while let f = run.first, leadingWords.contains(f.lowercased()) { run.removeFirst() }   // "The Catavan" thành "Catavan"
            // Chữ đầu câu đứng một mình thường chỉ viết hoa theo quy tắc, trừ khi đó là lời gọi có dấu phẩy ("Geralt, meet me...").
            let vocative = words[i].hasSuffix(",")
            let soloAtStart = sentenceStart && run.count == 1 && j - i == 1 && !vocative
            if !run.isEmpty, !soloAtStart {
                let name = run.joined(separator: " ")
                if !result.contains(name) { result.append(name) }
            }
            sentenceStart = endsSentence(words[j - 1])
            i = j
        }
        return result
    }
}
