import Foundation

/// Lớp lọc chạy trước khi dịch, không tốn API và áp dụng cho mọi engine: bỏ chữ giao diện, số liệu, bản quyền, hướng dẫn phím.
/// Chỉ phủ các mẫu giao diện tiếng Anh phổ biến; chữ giao diện lạ vẫn dựa vào lời nhắc cho AI và danh sách "luôn bỏ qua".
enum SubtitleFilter {
    private static let menuWords: Set<String> = [
        "back", "options", "option", "settings", "setting", "inventory", "map", "quit", "resume", "save", "load", "continue",
        "new", "game", "exit", "menu", "controls", "control", "audio", "video", "graphics", "sound", "skip", "confirm", "select",
        "equipment", "skills", "skill", "quests", "quest", "journal", "codex", "status", "items", "item", "party", "auto", "log",
        "help", "credits", "language", "display", "gameplay", "accessibility", "keyboard", "mouse", "gamepad", "brightness",
        "volume", "subtitles", "apply", "default", "defaults", "reset", "return", "title", "screen", "pause", "paused", "retry",
        "restart", "start", "play", "mode", "difficulty", "easy", "normal", "hard", "on", "off", "cancel", "ok", "next", "previous",
        "close", "open", "sell", "buy", "equip", "unequip", "use", "drop", "craft", "upgrade", "shop", "store", "stats", "attributes",
    ]

    private static let regexes: [(String, NSRegularExpression)] = {
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }
        return [
            ("bản quyền", rx(#"(?i)©|\(c\)\s*\d{4}|all rights reserved|™|®"#)),
            ("thông báo hệ thống", rx(#"(?i)^\s*(now\s+)?(loading|saving|autosav(e|ing)|please wait|connecting|downloading|installing)\b"#)),
            // Chỉ coi là nhãn phím khi trong ngoặc là tên phím; "[Sighs]", "(laughing)" là chú thích hành động trong lời thoại.
            ("nhãn phím trong ngoặc", rx(#"^\s*[\[\(<]\s*(?:[A-Z0-9]{1,3}|(?i:esc|escape|enter|return|tab|space|shift|ctrl|alt|lmb|rmb|mouse|click|lb|rb|lt|rt|ls|rs|d-pad|dpad|f\d{1,2}|[a-z]\s*\+\s*[a-z]))\s*[\]\)>]\s*\S"#)),
            ("hướng dẫn phím", rx(#"^\s*(?i:press|hold|tap|click|push|mash)\s+(?i:the\s+)?(?i:any\s+(?:button|key)|esc|escape|enter|return|tab|space(?:bar)?|shift|ctrl|alt|lmb|rmb|lb|rb|lt|rt|l[12]|r[12]|d-pad)\b"#)),
            ("hướng dẫn phím", rx(#"^\s*(?i:press|hold|tap|click|push|mash)\s+(?i:the\s+)?\[?[A-Z0-9]{1,3}\]?(\s|$)"#)),
            // Biểu tượng nút tay cầm bị OCR đọc thành chữ cái hoặc dấu chấm tròn: "Y Switch to Auto Playback", "• Skip", "Ⓑ Back".
            ("biểu tượng nút", rx(#"^\s*(?:[•●◉○◎▶►▷⏵Ⓐ-Ⓩⓐ-ⓩ⊕⊗]|(?:[BXY]|[LR][123]?|Z[LR]|LB|RB|LT|RT)(?=\s+\p{Lu}\p{Ll}))\s*\S"#)),
        ]
    }()

    /// Một hàng đơn lẻ chắc chắn là chữ giao diện (hướng dẫn phím, số liệu, bản quyền, thông báo hệ thống), để loại riêng
    /// trước khi gom các hàng thành lời thoại; không gộp nhầm "Press A to continue" vào câu thoại bên dưới.
    static func isUIRow(_ text: String) -> Bool {
        guard let r = nonSubtitleReason(text) else { return false }
        return ["hướng dẫn phím", "nhãn phím trong ngoặc", "biểu tượng nút", "điều khiển hội thoại", "chỉ có số hoặc ký hiệu", "số liệu",
                "bản quyền", "thông báo hệ thống"].contains(r)
    }

    static func isMenuVocabulary(_ words: [String]) -> Bool {
        !words.isEmpty && words.allSatisfy { menuWords.contains($0.lowercased()) }
    }

    /// Dùng cả bố cục các dòng OCR: nhiều dòng ngắn không dấu câu xếp chồng nhau là danh sách menu, không phải một câu thoại.
    static func nonSubtitleReason(lines: [String], joined: String) -> String? {
        if lines.count >= 3 {
            let shortLines = lines.allSatisfy { $0.split(separator: " ").count <= 3 }
            let sentenceEnd = lines.contains { l in
                guard let last = l.trimmingCharacters(in: .whitespaces).last else { return false }
                return ".!?…,。！？".contains(last)
            }
            if shortLines && !sentenceEnd { return "danh sách menu" }
        }
        return nonSubtitleReason(joined)
    }

    /// Lý do ở dạng hiện cho người dùng (theo ngôn ngữ giao diện). Các chuỗi lý do gốc vẫn dùng để so sánh trong mã.
    static func displayReason(_ reason: String) -> String {
        switch reason {
        case "bản quyền": return L("bản quyền", "copyright notice")
        case "thông báo hệ thống": return L("thông báo hệ thống", "system message")
        case "nhãn phím trong ngoặc": return L("nhãn phím trong ngoặc", "key label in brackets")
        case "hướng dẫn phím": return L("hướng dẫn phím", "button prompt")
        case "biểu tượng nút": return L("biểu tượng nút", "button icon")
        case "danh sách menu": return L("danh sách menu", "menu list")
        case "chỉ có số hoặc ký hiệu": return L("chỉ có số hoặc ký hiệu", "numbers or symbols only")
        case "số liệu": return L("số liệu", "numeric readout")
        case "điều khiển hội thoại": return L("điều khiển hội thoại", "dialogue controls")
        case "tên mục menu": return L("tên mục menu", "menu item")
        case "nhãn chỉ số": return L("nhãn chỉ số", "stat label")
        case "chữ in hoa ngắn (tiêu đề, nút)": return L("chữ in hoa ngắn (tiêu đề, nút)", "short all-caps text (title, button)")
        case "nhãn ngắn không dấu câu": return L("nhãn ngắn không dấu câu", "short label without punctuation")
        case "mẩu chữ rời": return L("mẩu chữ rời", "stray text fragment")
        case "nhãn viết tắt": return L("nhãn viết tắt", "abbreviated label")
        default: return reason
        }
    }

    /// Lý do đây không phải phụ đề, hoặc nil nếu có vẻ là lời thoại.
    static func nonSubtitleReason(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.filter(\.isLetter).count
        let digits = text.filter(\.isNumber).count
        if letters < 2 { return "chỉ có số hoặc ký hiệu" }
        if letters <= 4 && digits >= letters { return "số liệu" }

        let range = NSRange(text.startIndex..., in: text)
        for (reason, regex) in regexes where regex.firstMatch(in: text, range: range) != nil {
            if reason == "nhãn phím trong ngoặc" && text.split(separator: " ").count > 7 { continue }   // câu dài thì có thể là lời thoại
            if reason == "thông báo hệ thống" && text.split(separator: " ").count > 8 { continue }
            return reason
        }

        let words = text.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() }
        let speech = text.contains { "!?,".contains($0) }   // dấu than, hỏi, phẩy: nhiều khả năng là người đang nói

        // Nút điều khiển hội thoại hay nằm cạnh hộp thoại: "Switch to Auto Playback", "Skip", "Log", "Hide UI".
        let dialogueControls: Set<String> = ["auto", "playback", "skip", "log", "backlog", "history", "fast", "forward", "hide", "ui"]
        if !speech, !text.contains("."), words.count <= 5, words.contains(where: dialogueControls.contains) { return "điều khiển hội thoại" }
        if !speech, !words.isEmpty, words.count <= 3, words.allSatisfy({ menuWords.contains($0) }) { return "tên mục menu" }

        // Nhãn chỉ số: "Level 12", "Lv. 5", "HP 120", "Chapter 3" (còn tiêu đề phía sau thì giữ lại).
        if let m = try? NSRegularExpression(pattern: #"(?i)^(level|lv\.?|lvl|chapter|stage|round|wave|floor|rank|day|score|exp|xp|hp|mp|sp)\s*[:.]?\s*\d+(.*)$"#)
            .firstMatch(in: text, range: range), let r = Range(m.range(at: 2), in: text) {
            let rest = text[r].split { !$0.isLetter }.count
            if rest <= 2 { return "nhãn chỉ số" }
        }

        if !speech, text.count <= 24, words.count <= 3, text.filter(\.isLetter).allSatisfy(\.isUppercase) { return "chữ in hoa ngắn (tiêu đề, nút)" }

        // Chữ giao diện của từng game không liệt kê hết bằng danh sách từ. Nhật ký 07–08/10/2026 (Monster Hunter Stories, chế độ Chữ
        // chạy, AI không phân loại): 2.437 trên 2.458 dòng OCR lọt qua lớp luật, 69 câu ngắn được đọc ("Armor Info", "Set as Favorite",
        // "* Power Attack", "Wyvernfell Ab. Stat.", tên quái, tên nhân vật đứng một mình, mẩu OCR "ng", "o of o . ."). Lời thoại gần
        // như luôn có dấu câu, nên cụm ngắn không có dấu câu là nhãn. Không xét chữ Nhật, Trung, Hàn: không tách từ bằng dấu cách và
        // hay bỏ dấu câu. Câu đang được game gõ dần chỉ bị chậm vài khung: khi có dấu phẩy hoặc dài quá 5 từ thì được dịch bình thường.
        let cjk = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        if !cjk, words.count <= 5 {
            if !text.contains(where: { ".!?…,。！？、，".contains($0) }) { return "nhãn ngắn không dấu câu" }
            // Mẩu câu rời do OCR đọc trượt đầu dòng ("ated state.", "o of o . ."): bắt đầu bằng chữ thường. Câu bắt đầu bằng "..." thì không tính.
            if let first = text.first, first.isLetter, first.isLowercase { return "mẩu chữ rời" }
            // Nhãn viết tắt kiểu "Wyvernfell Ab. Stat.", "Drowning Shaft Lv.": từ nào cũng viết hoa, dấu chấm chỉ đứng sau chữ viết tắt
            // (tối đa 4 chữ cái), và có ít nhất một từ dài không kết thúc bằng dấu chấm (để "Oh. Okay." hay "Hmm. Yes." vẫn là lời thoại).
            let tokens = text.split(separator: " ").map(String.init)
            if !speech, tokens.count >= 2 {
                var titleCase = true, dotsOK = true, hasLongWord = false
                for t in tokens {
                    let core = t.trimmingCharacters(in: .punctuationCharacters)
                    guard let f = core.first, f.isLetter else { continue }
                    if f.isLowercase, core.count > 3 { titleCase = false }
                    if t.hasSuffix("."), !(f.isUppercase && core.count <= 4) { dotsOK = false }
                    if f.isUppercase, core.count >= 4, !t.hasSuffix(".") { hasLongWord = true }
                }
                if titleCase, dotsOK, hasLongWord { return "nhãn viết tắt" }
            }
        }
        return nil
    }
}
