import Foundation
import NaturalLanguage

enum TextUtil {
    /// Vị trí cuối các câu đã trọn vẹn (kết thúc bằng . ! ? … và có khoảng trắng phía sau) nằm sau `after` ký tự; nil nếu chưa có câu mới.
    static func completedSentences(_ text: String, after: Int) -> Int? {
        let chars = Array(text)
        guard chars.count > after + 1 else { return nil }
        var cut: Int?
        var i = max(after, 0)
        while i < chars.count - 1 {
            if ".!?…。！？".contains(chars[i]), chars[i + 1] == " " { cut = i + 1 }
            i += 1
        }
        guard let c = cut, c - after >= 8 else { return nil }   // câu quá ngắn thì gom tiếp, đọc liền mạch hơn
        return c
    }

    /// Phần còn lại cần đọc khi đã có bản dịch cuối: bỏ đi số từ đã đọc sớm (bản cuối có thể khác chút do trả tên riêng, bỏ khoảng trắng).
    static func remainder(of final: String, afterSpoken spoken: String) -> String {
        guard !spoken.isEmpty else { return final }
        if final.hasPrefix(spoken) { return String(final.dropFirst(spoken.count)).trimmingCharacters(in: .whitespaces) }
        let n = spoken.split(separator: " ").count
        return final.split(separator: " ").dropFirst(n).joined(separator: " ")
    }

    /// Chữ trong khung đã là ngôn ngữ đích (khác ngôn ngữ trong game) thì không cần dịch hay đọc:
    /// thường là cửa sổ app khác đè lên khung. Chỉ xét câu đủ dài và nhận diện chắc chắn để không bỏ nhầm tên riêng.
    static func isAlreadyTarget(_ text: String, target: String, source: String) -> Bool {
        let tBase = String(target.split(separator: "-").first ?? Substring(target))
        let sBase = String(source.split(separator: "-").first ?? Substring(source))
        guard tBase != sBase, text.filter(\.isLetter).count >= 12 else { return false }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first else { return false }
        let base = String(lang.rawValue.split(separator: "-").first ?? Substring(lang.rawValue))
        return base == tBase && p >= 0.8
    }

    /// Chữ thường, chỉ giữ chữ và số, để so sánh hai lần OCR không bị lệch vì dấu câu.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Độ giống nhau của hai chuỗi (hệ số Dice trên cặp ký tự liền nhau), 0 đến 1. Chịu được Vision đọc lệch vài ký tự giữa
    /// các khung hình, dùng để biết chữ trên màn hình có thật sự đổi không.
    static func dice(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let x = Array(a), y = Array(b)
        guard x.count > 1, y.count > 1 else { return 0 }
        var bag: [String: Int] = [:]
        for i in 0..<(x.count - 1) { bag[String(x[i...i + 1]), default: 0] += 1 }
        var inter = 0
        for i in 0..<(y.count - 1) {
            let k = String(y[i...i + 1])
            if let c = bag[k], c > 0 { inter += 1; bag[k] = c - 1 }
        }
        return 2 * Double(inter) / Double(x.count + y.count - 2)
    }

    /// Hai chuỗi đã chuẩn hoá coi là cùng một câu nếu khác nhau không quá ~12%.
    static func similar(_ a: String, _ b: String, tolerance: Double = 0.12) -> Bool {
        if a == b { return !a.isEmpty }
        if a.isEmpty || b.isEmpty { return false }
        let x = Array(a.prefix(400)), y = Array(b.prefix(400))
        let longest = max(x.count, y.count)
        if Double(abs(x.count - y.count)) > Double(longest) * tolerance { return false }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return Double(prev[y.count]) / Double(longest) <= tolerance
    }
}

extension TextUtil {
    /// Phần chữ gốc còn lại sau khi bỏ `n` ký tự chữ-số đầu (đếm giống `normalize`), đã cắt khoảng trắng và dấu đầu dòng thừa.
    static func suffix(of raw: String, afterAlnum n: Int) -> String {
        var count = 0
        var idx = raw.startIndex
        while idx < raw.endIndex, count < n {
            if raw[idx].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { count += 1 }
            idx = raw.index(after: idx)
        }
        // Dấu câu ngay sau phần đã dịch (vd "maintenance" rồi ",") thuộc về cụm trước, không để rơi sang đầu cụm sau.
        let trailing: Set<Character> = [",", ";", ":", ".", "!", "?", "…", "—", "、", "。", "！", "？", "，", "；", "：",
                                        ")", "]", "}", "\"", "”", "’", "」", "』"]
        while idx < raw.endIndex, raw[idx].isWhitespace || trailing.contains(raw[idx]) { idx = raw.index(after: idx) }
        return String(raw[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Dịch dần: chữ đang hiện từng ký tự thì cắt ra từng cụm đã hiện xong để dịch, cụm đã dịch không dịch lại.
enum Progressive {
    private static let boundaries: Set<Character> = [",", ";", ":", ".", "!", "?", "…", "—", "、", "。", "！", "？", "，", "；", "："]

    private static let danglers: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "by", "from", "and", "or", "but", "as", "if", "that",
        "which", "who", "your", "my", "his", "her", "their", "our", "its", "this", "these", "those", "is", "are", "was",
        "were", "be", "out", "up", "off", "over", "down", "so", "than", "into", "about", "since", "until", "during", "after",
        "before", "because", "when", "while", "where", "then", "not", "very", "just", "also", "still", "will", "would", "can",
        "could", "should", "have", "has", "had", "been", "do", "does", "did",
    ]

    /// Chữ mới đọc được có nối tiếp phần đã dịch không (cùng một câu đang dài ra), hay là câu khác.
    static func continues(norm: String, committedNorm: String) -> Bool {
        guard !committedNorm.isEmpty else { return false }
        if norm.hasPrefix(committedNorm) { return true }
        // OCR có thể đọc sai vài ký tự ở phần đã dịch.
        guard norm.count >= committedNorm.count else { return false }
        return TextUtil.similar(String(norm.prefix(committedNorm.count)), committedNorm, tolerance: 0.15)
    }

    /// Cụm có thể dịch ngay, hoặc nil nếu chưa đủ. `stable` = khung hình đã đứng yên, chữ không dài thêm nữa: dịch hết phần còn lại.
    static func nextChunk(latest raw: String, committedNorm: String, stable: Bool) -> String? {
        guard TextUtil.normalize(raw).count > committedNorm.count else { return nil }
        let delta = TextUtil.suffix(of: raw, afterAlnum: committedNorm.count)
        guard delta.filter(\.isLetter).count >= 2 else { return nil }
        if stable { return delta }

        // Đến dấu phẩy, dấu chấm... cuối cùng: cụm đã trọn ý.
        if let i = delta.lastIndex(where: { boundaries.contains($0) }) {
            let chunk = String(delta[...i])
            if chunk.filter(\.isLetter).count >= 3 { return chunk }
        }
        // Chưa có dấu câu: dịch khi đủ vài từ, bỏ từ cuối vì có thể mới hiện nửa chừng, và không dừng ở từ nối
        // (a, the, of, to, your, out...) vì cắt giữa cụm làm bản dịch sai nghĩa; những từ đó để dành cho cụm sau.
        if delta.contains(" ") {
            var words = Array(delta.split(separator: " ").dropLast())
            guard words.count >= 7 else { return nil }
            while words.count > 3, let last = words.last, danglers.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                words.removeLast()
            }
            return words.joined(separator: " ")
        } else if delta.count >= 10 {   // tiếng Nhật, Trung không có dấu cách
            return String(delta.dropLast(2))
        }
        return nil
    }
}
