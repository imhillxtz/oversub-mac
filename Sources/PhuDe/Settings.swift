import Foundation
import SwiftUI
import Security

/// Hiện gì ở phụ đề và cửa sổ app. Giữ tên gốc (viOnly...) để cài đặt và preset cũ vẫn đọc được.
enum DisplayMode: String, CaseIterable, Identifiable {
    case viOnly, viAndEn, audioOnly
    var showsOriginal: Bool { self != .viOnly }
    var translates: Bool { self != .audioOnly }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .viOnly: return L("Bản dịch", "Translation")
        case .viAndEn: return L("Bản dịch + câu gốc", "Translation + original")
        case .audioOnly: return L("Chỉ đọc to câu gốc", "Read original aloud only")
        }
    }
}

/// Đầu ra của OverSub: phụ đề, thuyết minh (đọc to bản dịch), hay cả hai. Giữ tên gốc "dub" cho chế độ chỉ đọc để preset cũ vẫn đọc được.
enum OutputMode: String, CaseIterable, Identifiable, Codable {
    case subtitles, both, dub
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subtitles: return L("Chỉ phụ đề", "Subtitles only")
        case .both: return L("Phụ đề + giọng đọc", "Subtitles + voice")
        case .dub: return L("Chỉ giọng đọc", "Voice only")
        }
    }
    var icon: String {
        switch self {
        case .subtitles: return "captions.bubble"
        case .both: return "captions.bubble.fill"
        case .dub: return "speaker.wave.2"
        }
    }
    var showsSubtitles: Bool { self != .dub }
    var speaks: Bool { self != .subtitles }
}

/// Nguồn giọng lồng tiếng.
enum VoiceSource: String, CaseIterable, Identifiable, Codable {
    case apple, gemini
    var id: String { rawValue }
    var title: String { self == .apple ? L("Giọng Apple", "Apple voice") : "Gemini TTS" }
}

enum OverlayStyle: String, CaseIterable, Identifiable {
    case matchOriginal, glass, darkSolid, darkGlass, transparent, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matchOriginal: return L("Khớp màu phụ đề gốc", "Match original subtitle colors")
        case .glass: return L("Kính mờ", "Frosted glass")
        case .darkSolid: return L("Chữ sáng, nền đen", "Light text, black background")
        case .darkGlass: return L("Chữ sáng, nền đen mờ", "Light text, dimmed black background")
        case .transparent: return L("Chữ sáng, không nền", "Light text, no background")
        case .light: return L("Chữ tối, nền sáng", "Dark text, light background")
        }
    }
    var foreground: Color { self == .light ? .black : .white }
    var background: Color {
        switch self {
        case .darkSolid: return .black
        case .matchOriginal: return Color.black.opacity(0.85)   // chỉ dùng khi chưa lấy được màu gốc
        case .glass: return .clear   // nền kính vẽ riêng bằng glassEffect
        case .darkGlass: return Color.black.opacity(0.6)
        case .transparent: return .clear
        case .light: return Color.white.opacity(0.92)
        }
    }
}

struct SourceLanguage: Identifiable, Hashable {
    let name: String
    let ocr: String      // mã cho Vision OCR
    let speech: String   // mã cho giọng đọc khi chế độ "chỉ đọc"
    let code: String     // mã ngôn ngữ cho Apple Translation
    var id: String { ocr }
    var english: String {
        ["en": "English", "ja": "Japanese", "ko": "Korean", "zh-Hans": "Chinese", "fr": "French", "de": "German", "es": "Spanish", "ru": "Russian"][code] ?? "English"
    }
    /// Tên hiện trên giao diện: tiếng Anh khi giao diện là tiếng Anh. Lời nhắc AI vẫn dùng `name` / `english`.
    var displayName: String { L(name, code == "zh-Hans" ? "Chinese (Simplified)" : english) }

    static let all: [SourceLanguage] = [
        .init(name: "Tiếng Anh", ocr: "en-US", speech: "en-US", code: "en"),
        .init(name: "Tiếng Nhật", ocr: "ja-JP", speech: "ja-JP", code: "ja"),
        .init(name: "Tiếng Hàn", ocr: "ko-KR", speech: "ko-KR", code: "ko"),
        .init(name: "Tiếng Trung (giản thể)", ocr: "zh-Hans", speech: "zh-CN", code: "zh-Hans"),
        .init(name: "Tiếng Pháp", ocr: "fr-FR", speech: "fr-FR", code: "fr"),
        .init(name: "Tiếng Đức", ocr: "de-DE", speech: "de-DE", code: "de"),
        .init(name: "Tiếng Tây Ban Nha", ocr: "es-ES", speech: "es-ES", code: "es"),
        .init(name: "Tiếng Nga", ocr: "ru-RU", speech: "ru-RU", code: "ru"),
    ]
    static func find(_ ocr: String) -> SourceLanguage { all.first { $0.ocr == ocr } ?? all[0] }
}

enum OverlayAlign: String, CaseIterable, Identifiable {
    case auto, leading, center, trailing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Theo phụ đề gốc", "Match original subtitles")
        case .leading: return L("Căn trái", "Left")
        case .center: return L("Căn giữa", "Center")
        case .trailing: return L("Căn phải", "Right")
        }
    }
    var textAlignment: TextAlignment? {
        switch self {
        case .auto: return nil
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// Thể loại game, phân theo hệ xưng hô và giọng văn tiếng Việt (không phải theo đề tài), vì đó mới quyết định bản dịch.
enum GameGenre: String, CaseIterable, Identifiable {
    case auto, medieval, modern, school, street, western, eastern, epic, military, scifi, horror, adventure, anime, cozy, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L("Tự động (AI tự chọn theo ngữ cảnh)", "Automatic (AI picks from context)")
        case .modern: return L("Hiện đại / Đời thường (Detroit, The Sims...)", "Modern / Everyday (Detroit, The Sims...)")
        case .school: return L("Học đường / Thanh xuân (Persona, Life is Strange...)", "School / Coming of age (Persona, Life is Strange...)")
        case .street: return L("Đường phố / Băng đảng (GTA, Mafia...)", "Street / Gangs (GTA, Mafia...)")
        case .western: return L("Viễn Tây / Cao bồi (Red Dead...)", "Wild West / Cowboys (Red Dead...)")
        case .eastern: return L("Cổ trang / Kiếm hiệp (Sekiro, Black Myth: Wukong...)", "Historical East Asia / Wuxia (Sekiro, Black Myth: Wukong...)")
        case .epic: return L("Thần thoại / Sử thi (God of War, Hades...)", "Mythology / Epic (God of War, Hades...)")
        case .medieval: return L("Trung cổ châu Âu (Elden Ring, KCD 2, Fire Emblem, Monster Hunter...)", "Medieval Europe (Elden Ring, KCD 2, Fire Emblem, Monster Hunter...)")
        case .military: return L("Chiến tranh / Quân sự (Call of Duty, Battlefield...)", "War / Military (Call of Duty, Battlefield...)")
        case .scifi: return L("Khoa học viễn tưởng / Cyberpunk (Cyberpunk 2077, Mass Effect...)", "Sci-fi / Cyberpunk (Cyberpunk 2077, Mass Effect...)")
        case .horror: return L("Kinh dị / Sinh tồn (The Last of Us, Resident Evil...)", "Horror / Survival (The Last of Us, Resident Evil...)")
        case .adventure: return L("Phiêu lưu điện ảnh (Uncharted, Tomb Raider...)", "Cinematic adventure (Uncharted, Tomb Raider...)")
        case .anime: return "Anime / JRPG (Genshin, Final Fantasy, Zelda...)"
        case .cozy: return L("Nhẹ nhàng / Gia đình (Animal Crossing, Stardew Valley, Kirby...)", "Cozy / Family (Animal Crossing, Stardew Valley, Kirby...)")
        case .custom: return L("Tuỳ chỉnh (tự viết hướng dẫn cho AI)", "Custom (write your own guide for the AI)")
        }
    }

    /// Gợi ý văn phong cho ngôn ngữ đích không phải tiếng Việt (lời nhắc tiếng Anh).
    var englishHint: String {
        switch self {
        case .auto: return "Infer the game's genre and tone from the content and keep it consistent."
        case .medieval: return "Medieval European setting (realistic or fantasy): address depends on social rank; commoners speak deferentially to lords and knights, nobles speak down to inferiors; slightly archaic but readable, no modern slang; keep titles, names, monsters and spells."
        case .modern: return "Modern everyday speech, natural and casual."
        case .school: return "Teen/school setting: casual, playful, light slang; keep honorifics like -san, -senpai if present."
        case .street: return "Street/gang setting: rough, short, slangy; match the original's profanity level."
        case .western: return "American Old West: rugged, folksy cowboy speech, no modern tech words."
        case .eastern: return "East Asian historical/wuxia: formal, archaic, martial-arts register."
        case .epic: return "Epic mythology: grand, solemn, short commanding sentences."
        case .military: return "Military: terse, clipped orders, standard military terms; keep call signs."
        case .scifi: return "Sci-fi/cyberpunk: cool, concise; keep tech terms and names."
        case .horror: return "Horror/survival: tense, whispered, short broken sentences."
        case .adventure: return "Cinematic adventure: witty, quick banter."
        case .anime: return "Anime/JRPG: strong character voices; keep honorifics and move names."
        case .cozy: return "Cozy/family: warm, cute, friendly."
        case .custom: return CustomStyle.current.guide(vietnamese: false) ?? GameGenre.auto.englishHint
        }
    }

    /// Hướng dẫn văn phong đưa vào lời nhắc (ngắn, vì Groq miễn phí chỉ có 8.000 token mỗi phút).
    var styleGuide: String {
        switch self {
        case .auto: return "Tự suy ra thể loại game và giọng văn từ nội dung rồi giữ nhất quán."
        case .modern: return "Văn nói hiện đại, tự nhiên. Xưng hô theo tuổi và quan hệ (anh/chị/em, tôi – bạn, tớ – cậu). Tránh từ cổ và Hán Việt nặng. Ví dụ: Get some rest, you look exhausted. → Nghỉ ngơi đi, trông cậu mệt lắm rồi."
        case .school: return "Giọng học sinh, thanh niên, thân mật, câu ngắn, tiếng lóng nhẹ. Xưng hô tớ – cậu, mình – bạn, anh/chị – em. Giữ hậu tố kính ngữ -san, -senpai nếu bản gốc có. Ví dụ: I'm telling you, it's not what it looks like! → Tớ nói thật mà, không phải như cậu nghĩ đâu!"
        case .street: return "Giọng đường phố, băng đảng: thô, ngắn, tiếng lóng. Với người ngang hàng hoặc kẻ thù dùng tao – mày, thằng, con, tụi mày; với đại ca hoặc người lạ đáng nể dùng anh – em, ông – tôi. Mức chửi thề theo đúng bản gốc. Ví dụ: Get out of my face, punk. → Cút khỏi mắt tao, thằng ranh."
        case .western: return "Giọng cao bồi miền Tây nước Mỹ cuối thế kỷ 19: thô mộc, chậm rãi. Dùng tôi – ông/anh/cô, lão, gã, ông bạn, thưa ngài, bà chủ. Không dùng từ công nghệ hiện đại. Ví dụ: Easy now, stranger. → Từ từ thôi, anh bạn lạ."
        case .eastern: return "Cổ trang, kiếm hiệp: trang trọng, cổ kính. Xưng hô ta – ngươi, huynh – đệ, tỷ – muội, tại hạ – các hạ, sư phụ, thiếu hiệp, bệ hạ. Dùng Hán Việt vừa phải, câu gọn. Ví dụ: I will not yield. → Tại hạ quyết không lui."
        case .epic: return "Sử thi thần thoại: uy nghiêm, nặng nề, câu ngắn dứt khoát. Xưng hô ta – ngươi, các vị thần, kẻ phàm trần, cha – con. Không dùng tiếng lóng hiện đại. Ví dụ: Face me, mortal. → Đối mặt với ta đi, kẻ phàm trần."
        case .medieval: return "Trung cổ châu Âu, thực tế lẫn giả tưởng: xưng hô theo ĐỊA VỊ. Dân thường, lính, thợ săn nói với quý tộc, hiệp sĩ, chỉ huy hay người lớn tuổi: tôi – ngài/ông/bà, thưa ngài, thưa bà. Quý tộc, chỉ huy nói với kẻ dưới hoặc kẻ thù: ta – ngươi (lịch sự thì ta – các hạ). Đồng đội và bạn thân: tôi – anh/cậu; chỉ dùng tao – mày với dân quê thô hoặc khi bản gốc thô tục. Giữ chức danh (lãnh chúa, hiệp sĩ, thợ săn, thủ lĩnh), tên riêng, địa danh, tên quái vật và phép thuật. Giọng hơi cổ nhưng dễ hiểu, không dùng từ hiện đại hay tiếng lóng. Ví dụ: My lord, the gates have fallen. → Thưa ngài, cổng thành đã thất thủ."
        case .military: return "Quân sự: câu ngắn, dứt khoát, mệnh lệnh. Tôi – anh/đồng chí; với cấp trên: thưa chỉ huy, thưa sếp. Thuật ngữ quân sự chuẩn (tiểu đội, mục tiêu, rõ!), giữ mật danh và tên riêng. Ví dụ: Copy that, moving out. → Rõ, xuất phát."
        case .scifi: return "Khoa học viễn tưởng, cyberpunk: giọng lạnh, gọn. Tôi – anh/cô/ông. Giữ thuật ngữ công nghệ và tên riêng; tiếng lóng đường phố công nghệ nếu bản gốc có. Ví dụ: The system's been compromised. → Hệ thống đã bị xâm nhập."
        case .horror: return "Kinh dị, sinh tồn: giọng căng thẳng, thì thầm, câu ngắn, ngắt quãng, đôi khi hoảng loạn. Tôi – anh/cô/cậu. Không gượng trang trọng. Ví dụ: Quiet... did you hear that? → Im... anh nghe thấy không?"
        case .adventure: return "Phiêu lưu điện ảnh: dí dỏm, nhanh, đối đáp hài hước. Tôi – anh/cô, cậu – tớ khi thân. Câu cảm thán tự nhiên. Ví dụ: Well, that went smoothly. → Chà, trơn tru ghê."
        case .anime: return "Anime, JRPG: giọng nhân vật rõ nét theo tính cách (nóng nảy, nhút nhát, kiêu kỳ). Xưng hô theo tuổi và quan hệ (tớ – cậu, anh/chị – em, ta – ngươi cho nhân vật cổ hoặc kiêu). Giữ hậu tố -san, -kun, -chan, senpai và tên chiêu thức. Ví dụ: I won't lose to you! → Tớ sẽ không thua cậu đâu!"
        case .cozy: return "Nhẹ nhàng, dễ thương, thân thiện. Tớ – cậu, mình – bạn, anh/chị/em với trẻ nhỏ. Câu cảm thán đáng yêu, từ láy; giữ tên nhân vật và địa danh, chỉ dịch khi là chơi chữ. Ví dụ: Let's have tea together! → Mình cùng uống trà nhé!"
        case .custom: return CustomStyle.current.guide(vietnamese: true) ?? GameGenre.auto.styleGuide
        }
    }
}

/// Hướng dẫn dịch do người dùng tự viết cho thể loại "Tuỳ chỉnh". Lưu theo hồ sơ game.
struct CustomStyle: Codable, Equatable {
    enum Formality: String, Codable, CaseIterable, Identifiable {
        case auto, casual, formal, archaic, rough
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return L("Theo bản gốc", "Follow the original")
            case .casual: return L("Thân mật, đời thường", "Casual, everyday")
            case .formal: return L("Lịch sự, trang trọng", "Polite, formal")
            case .archaic: return L("Cổ kính", "Archaic")
            case .rough: return L("Bụi bặm, thô", "Rough, gritty")
            }
        }
        var vi: String? {
            switch self {
            case .auto: return nil
            case .casual: return "thân mật, đời thường, văn nói tự nhiên"
            case .formal: return "lịch sự, trang trọng"
            case .archaic: return "cổ kính, không dùng từ hiện đại hay tiếng lóng"
            case .rough: return "bụi bặm, thô, câu ngắn"
            }
        }
        var en: String? {
            switch self {
            case .auto: return nil
            case .casual: return "casual, everyday spoken language"
            case .formal: return "polite and formal"
            case .archaic: return "archaic, no modern words or slang"
            case .rough: return "rough and gritty, short sentences"
            }
        }
    }
    enum Profanity: String, Codable, CaseIterable, Identifiable {
        case asIs, soften, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .asIs: return L("Giữ như bản gốc", "Keep as in the original")
            case .soften: return L("Nói giảm", "Soften")
            case .none: return L("Bỏ hẳn", "Remove")
            }
        }
    }

    var world = ""          // game gì, thế giới, thời đại
    var characters = ""     // nhân vật chính và quan hệ
    var address = ""        // cách xưng hô mong muốn
    var tone = ""           // giọng văn
    var extra = ""          // yêu cầu khác, viết tự do
    var formality = Formality.auto
    var profanity = Profanity.asIs
    var keepHonorifics = true

    /// Mỗi ô tối đa chừng này ký tự khi đưa vào lời nhắc, để không vượt hạn mức token mỗi phút của gói miễn phí.
    static let fieldLimit = 400

    var isEmpty: Bool {
        [world, characters, address, tone, extra].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && formality == .auto && profanity == .asIs
    }

    /// Bản đang dùng (đọc từ nơi lưu cài đặt, để phần dựng lời nhắc không phải cầm theo AppSettings).
    static var current: CustomStyle {
        UserDefaults.standard.data(forKey: "customStyle").flatMap { try? JSONDecoder().decode(CustomStyle.self, from: $0) } ?? CustomStyle()
    }

    /// Đoạn hướng dẫn đưa vào lời nhắc. nil nếu người dùng chưa điền gì.
    func guide(vietnamese: Bool) -> String? {
        guard !isEmpty else { return nil }
        func clip(_ t: String) -> String? {
            let v = t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            return v.isEmpty ? nil : String(v.prefix(Self.fieldLimit))
        }
        var lines: [String] = [vietnamese ? "theo đúng các chỉ dẫn của người chơi dưới đây." : "follow the player's instructions below."]
        func add(_ vi: String, _ en: String, _ value: String?) {
            if let value { lines.append("- \(vietnamese ? vi : en): \(value)") }
        }
        add("Bối cảnh game", "Game and setting", clip(world))
        add("Nhân vật và quan hệ", "Characters and relationships", clip(characters))
        add("Xưng hô", "Forms of address", clip(address))
        var toneParts = [clip(tone), vietnamese ? formality.vi : formality.en].compactMap { $0 }
        if profanity == .soften { toneParts.append(vietnamese ? "chửi thề thì nói giảm" : "soften profanity") }
        if profanity == .none { toneParts.append(vietnamese ? "không dùng từ chửi thề" : "no profanity") }
        add("Giọng văn", "Tone", toneParts.isEmpty ? nil : toneParts.joined(separator: "; "))
        if keepHonorifics { add("Kính ngữ", "Honorifics", vietnamese ? "giữ hậu tố -san, -kun, -chan, senpai nếu bản gốc có" : "keep -san, -kun, -chan, senpai if present") }
        add("Yêu cầu khác", "Other instructions", clip(extra))
        return lines.joined(separator: "\n")
    }
}

enum EngineKind: String, CaseIterable, Codable, Identifiable {
    case appleTranslation, appleAI, gemini, groq, cerebras, mistral, openRouter, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleTranslation: return L("Dịch máy Apple", "Apple Translation")
        case .appleAI: return "Apple Intelligence"
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .cerebras: return "Cerebras"
        case .mistral: return "Mistral"
        case .openRouter: return "OpenRouter"
        case .custom:
            let name = (UserDefaults.standard.string(forKey: "customEngineName") ?? "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? L("Dịch vụ tự thêm", "Custom service") : name
        }
    }
    var detail: String {
        switch self {
        case .appleTranslation: return L("Dịch trên máy, offline, không giới hạn", "On-device translation, offline, unlimited")
        case .appleAI: return L("AI trên máy (model của Siri), offline, không giới hạn", "On-device AI (Siri's model), offline, unlimited")
        case .gemini: return L("API miễn phí của Google, cần key", "Google's free API, needs an API key")
        case .groq: return L("API miễn phí của Groq, rất nhanh, cần key", "Groq's free API, very fast, needs an API key")
        case .cerebras: return L("API miễn phí của Cerebras, rất nhanh, cần key", "Cerebras's free API, very fast, needs an API key")
        case .mistral: return L("API miễn phí của Mistral, hạn mức rộng, cần key", "Mistral's free API, generous quota, needs an API key")
        case .openRouter: return L("Một key dùng nhiều model, có model miễn phí", "One key for many models, some of them free")
        case .custom: return L("Dịch vụ trả phí kiểu OpenAI (OpenAI, DeepSeek, xAI…)", "Paid OpenAI-style service (OpenAI, DeepSeek, xAI…)")
        }
    }
    var needsKey: Bool { self != .appleAI && self != .appleTranslation }
    /// Các dịch vụ dùng chung kiểu API của OpenAI (chat/completions).
    var isOpenAIStyle: Bool { needsKey && self != .gemini }
    /// Nơi lấy key.
    var keyLink: String {
        switch self {
        case .gemini: return "https://aistudio.google.com/apikey"
        case .groq: return "https://console.groq.com/keys"
        case .cerebras: return "https://cloud.cerebras.ai"
        case .mistral: return "https://console.mistral.ai/api-keys"
        case .openRouter: return "https://openrouter.ai/keys"
        default: return ""
        }
    }
    /// Địa chỉ API (không gồm /chat/completions). Dịch vụ tự thêm lấy theo ô người dùng nhập.
    var baseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom:
            var u = (UserDefaults.standard.string(forKey: "customEngineURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            while u.hasSuffix("/") { u.removeLast() }
            if u.hasSuffix("/chat/completions") { u.removeLast("/chat/completions".count) }
            return u
        default: return ""
        }
    }
    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-flash-lite-latest"
        case .groq: return "llama-3.3-70b-versatile"
        case .cerebras: return "gpt-oss-120b"
        case .mistral: return "mistral-small-latest"
        case .openRouter: return "google/gemma-4-31b-it:free"
        default: return ""
        }
    }
    /// Thứ tự theo chất lượng dịch (ước lượng ban đầu; tốc độ thì đo thực tế).
    static let byQuality: [EngineKind] = [.gemini, .custom, .groq, .cerebras, .mistral, .openRouter, .appleAI, .appleTranslation]

    /// Thứ tự đã lưu ở bản cũ thiếu dịch vụ mới: chèn các dịch vụ còn thiếu vào trước nhóm Apple.
    static func completed(_ saved: [EngineKind]) -> [EngineKind] {
        var out: [EngineKind] = []
        for e in saved where !out.contains(e) { out.append(e) }
        let missing = byQuality.filter { !out.contains($0) }
        let at = out.firstIndex { !$0.needsKey } ?? out.count
        out.insert(contentsOf: missing.filter(\.needsKey), at: at)
        out.append(contentsOf: missing.filter { !$0.needsKey })
        return out
    }
    /// Làm theo được lời nhắc phức tạp (phân loại phụ đề, giữ xưng hô). Đo thực tế: Gemini và Groq tốt; Apple Intelligence bỏ nhầm
    /// lời thoại và xưng hô kỳ cục; Dịch máy Apple không nhận lệnh.
    var supportsSmartPrompt: Bool { needsKey }
    /// Giữ nguyên được mã tạm (Xqza...) qua quá trình dịch. Đo thực tế: Gemini, Groq, Dịch máy Apple giữ đủ; Apple Intelligence làm mất một nửa.
    var keepsPlaceholders: Bool { self != .appleAI }
}

enum EnginePreference: String, CaseIterable, Identifiable {
    case quality, speed, balanced, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quality: return L("Ưu tiên chất lượng", "Prefer quality")
        case .speed: return L("Ưu tiên tốc độ", "Prefer speed")
        case .balanced: return L("Cân bằng", "Balanced")
        case .custom: return L("Tuỳ chỉnh", "Custom")
        }
    }
    var detail: String {
        switch self {
        case .quality: return L("Dịch vụ AI qua mạng trước (Gemini đứng đầu vì dịch hay nhất), Apple làm dự phòng. Engine bị chậm hoặc lỗi sẽ tự xuống cuối.", "Online AI services first (Gemini leads for quality), Apple as backup. A slow or failing engine drops to the end automatically.")
        case .speed: return L("Engine trả lời nhanh nhất (theo độ trễ đo thực tế trong bảng trạng thái) đứng trước. Engine bị chậm hoặc lỗi sẽ tự xuống cuối.", "The fastest engine (by measured latency in the status table) goes first. A slow or failing engine drops to the end automatically.")
        case .balanced: return L("Cân giữa chất lượng và độ trễ đo thực tế. Engine bị chậm hoặc lỗi sẽ tự xuống cuối.", "Balances quality against measured latency. A slow or failing engine drops to the end automatically.")
        case .custom: return L("Theo đúng thứ tự bạn sắp xếp, chỉ bỏ qua engine đang lỗi.", "Uses exactly the order you set, skipping only engines that are failing.")
        }
    }
    var order: [EngineKind]? {
        switch self {
        case .quality: return EngineKind.byQuality
        case .speed: return [.groq, .cerebras, .mistral, .gemini, .custom, .openRouter, .appleAI, .appleTranslation]
        case .balanced: return [.groq, .gemini, .cerebras, .mistral, .custom, .openRouter, .appleAI, .appleTranslation]
        case .custom: return nil
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case balanced, progressive, complete
    var id: String { rawValue }

    /// Đọc giá trị đã lưu; chế độ "Nhanh" cũ đã gộp vào "Chữ chạy".
    static func from(_ raw: String?) -> CaptureMode? { raw == "fast" ? .progressive : raw.flatMap(CaptureMode.init(rawValue:)) }

    var title: String {
        switch self {
        case .balanced: return L("Cân bằng", "Balanced")
        case .progressive: return L("Chữ chạy", "Typewriter text")
        case .complete: return L("Chờ đủ câu", "Wait for full line")
        }
    }
    var detail: String {
        switch self {
        case .balanced: return L("Dịch cả câu khi chữ đã đứng yên một nhịp (khoảng 0,7 giây). Hợp với hầu hết game.", "Translates the whole line once the text has held still for a beat (about 0.7 seconds). Works for most games.")
        case .progressive: return L("Cho game chữ hiện từng ký tự hoặc thoại dồn dập: chữ hiện xong cụm nào (dấu phẩy, dấu chấm, đủ vài từ) thì dịch và đọc cụm đó ngay, cụm đã dịch không dịch lại. Phụ đề có sớm nhất, đổi lại các cụm dịch riêng nên có thể kém mượt hơn.", "For games where text appears letter by letter or dialogue comes fast: each phrase is translated and read as soon as it finishes appearing (a comma, a period, or a few words), and translated phrases are never redone. Subtitles arrive soonest, but phrases are translated separately so they may read less smoothly.")
        case .complete: return L("Chờ chữ đứng yên khoảng 1 giây rồi mới dịch cả câu. Chậm hơn một chút nhưng hầu như không dịch dở dang.", "Waits for the text to hold still for about 1 second, then translates the whole line. Slightly slower, but almost never translates a half-finished line.")
        }
    }
    var interval: Double {
        switch self {
        case .balanced: return 0.7
        case .progressive: return 0.35
        case .complete: return 0.5
        }
    }
}

/// Ngôn ngữ đích. Tiếng Việt là mặc định và có bộ lời nhắc riêng đã tinh chỉnh (xưng hô, thể loại);
/// các ngôn ngữ khác dùng bộ lời nhắc tiếng Anh chung.
struct TargetLanguage: Identifiable, Hashable {
    let code: String     // mã cho Apple Translation và bộ lời nhắc
    let name: String     // tên hiển thị
    let english: String  // tên tiếng Anh, dùng trong lời nhắc
    let speech: String   // mã giọng đọc
    var id: String { code }
    var isVietnamese: Bool { code == "vi" }
    /// Tên hiện trên giao diện: tiếng Anh khi giao diện là tiếng Anh. Lời nhắc AI vẫn dùng `english`.
    var displayName: String { L(name, english) }

    static let all: [TargetLanguage] = [
        .init(code: "vi", name: "Tiếng Việt", english: "Vietnamese", speech: "vi-VN"),
        .init(code: "en", name: "English", english: "English", speech: "en-US"),
        .init(code: "zh-Hans", name: "简体中文", english: "Simplified Chinese", speech: "zh-CN"),
        .init(code: "ja", name: "日本語", english: "Japanese", speech: "ja-JP"),
        .init(code: "ko", name: "한국어", english: "Korean", speech: "ko-KR"),
        .init(code: "th", name: "ไทย", english: "Thai", speech: "th-TH"),
        .init(code: "id", name: "Bahasa Indonesia", english: "Indonesian", speech: "id-ID"),
        .init(code: "es", name: "Español", english: "Spanish", speech: "es-ES"),
        .init(code: "fr", name: "Français", english: "French", speech: "fr-FR"),
        .init(code: "de", name: "Deutsch", english: "German", speech: "de-DE"),
        .init(code: "pt-BR", name: "Português (BR)", english: "Brazilian Portuguese", speech: "pt-BR"),
        .init(code: "ru", name: "Русский", english: "Russian", speech: "ru-RU"),
    ]
    static func find(_ code: String) -> TargetLanguage { all.first { $0.code == code } ?? all[0] }
    /// Mã ngôn ngữ ngắn (vi, en, zh...) để đối chiếu với lựa chọn giọng đọc của macOS.
    var base: String { String(code.split(separator: "-").first ?? Substring(code)) }
}

/// Vùng chụp, toạ độ tính theo điểm trong màn hình, gốc ở góc trên trái.
/// Tốc độ dịch màn hình.
enum ScreenSpeed: String, CaseIterable, Identifiable {
    case instant, balanced, quality
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instant: return L("Tức thì", "Instant")
        case .balanced: return L("Tức thì, rồi chuốt bằng AI", "Instant, then refined by AI")
        case .quality: return L("Chờ bản AI", "Wait for AI")
        }
    }
    var detail: String {
        switch self {
        case .instant: return L("Dịch máy Apple ngay trên máy: khoảng 0,2 đến 0,5 giây, không tốn lượt API, không cần mạng. Câu chữ đôi khi cứng.", "Apple Translation on your Mac: about 0.2 to 0.5 seconds, no API requests, no network needed. Wording can be stiff at times.")
        case .balanced: return L("Hiện ngay bản Dịch máy Apple, khoảng 1 đến 2 giây sau thay bằng bản AI mượt hơn. Chữ đã gặp thì hiện bản AI ngay từ trí nhớ.", "Shows the Apple Translation result right away, then replaces it with a smoother AI version 1 to 2 seconds later. Text seen before shows the AI version instantly from memory.")
        case .quality: return L("Chỉ hiện bản AI (Gemini, Groq): chậm hơn 1 đến 3 giây nhưng văn mượt, đúng thuật ngữ game. Chữ đã gặp thì hiện ngay từ trí nhớ.", "Shows only the AI version (Gemini, Groq): 1 to 3 seconds slower, but smoother and true to the game's terms. Text seen before shows instantly from memory.")
        }
    }
}

struct CaptureRegion: Codable, Equatable {
    var displayID: UInt32
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    // Kích thước màn hình lúc chọn, để tìm lại màn hình tương ứng khi ID màn hình đổi (cắm/rút màn hình).
    var sw: Double?
    var sh: Double?
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

enum Keychain {
    private static let service = "vn.imhillxtz.phude"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

func parseKeys(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var mode: DisplayMode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var overlayEnabled: Bool { didSet { d.set(overlayEnabled, forKey: "overlayEnabled") } }
    @Published var style: OverlayStyle { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var outputMode: OutputMode { didSet { d.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var voiceSource: VoiceSource { didSet { d.set(voiceSource.rawValue, forKey: "voiceSource") } }
    @Published var geminiTTSModel: String { didSet { d.set(geminiTTSModel, forKey: "geminiTTSModel") } }
    @Published var geminiTTSPaid: Bool { didSet { d.set(geminiTTSPaid, forKey: "geminiTTSPaid") } }
    @Published var geminiTTSIntroSeen: Bool { didSet { d.set(geminiTTSIntroSeen, forKey: "geminiTTSIntroSeen") } }
    @Published var geminiMaxWait: Double { didSet { d.set(geminiMaxWait, forKey: "geminiMaxWait") } }
    @Published var dubDeviceUID: String { didSet { d.set(dubDeviceUID, forKey: "dubDeviceUID") } }   // "" = theo hệ thống
    @Published var duckEnabled: Bool { didSet { d.set(duckEnabled, forKey: "duckEnabled") } }
    @Published var duckLevel: Double { didSet { d.set(duckLevel, forKey: "duckLevel") } }   // tiếng game còn lại khi đang đọc, 0...1
    @Published var dropStaleLines: Bool { didSet { d.set(dropStaleLines, forKey: "dropStaleLines") } }
    @Published var dubEmotion: Bool { didSet { d.set(dubEmotion, forKey: "dubEmotion") } }
    @Published var cast: [CastMember] {
        didSet { if let data = try? JSONEncoder().encode(cast) { d.set(data, forKey: "cast") } }
    }
    @Published var contextAutoForget: Bool { didSet { d.set(contextAutoForget, forKey: "contextAutoForget") } }
    /// Nâng cao, thử nghiệm: mỗi nhân vật một giọng. Tắt thì mọi câu đọc bằng một giọng thuyết minh (nhanh, đồng nhất).
    @Published var dubCharacters: Bool { didSet { d.set(dubCharacters, forKey: "dubCharacters") } }
    /// Hiện tạm bản Dịch máy Apple khi AI chưa trả lời kịp (phụ đề hiện gần như tức thì).
    @Published var quickAppleTranslation: Bool { didSet { d.set(quickAppleTranslation, forKey: "quickAppleTranslation") } }
    /// Dịch màn hình bật hay tắt (nút tròn thứ ba ở cửa sổ chính, ⌃⌥T). Chạy khi bấm Bắt đầu, như Phụ đề và Voice-over.
    @Published var screenTranslateEnabled: Bool { didSet { d.set(screenTranslateEnabled, forKey: "screenTranslateEnabled") } }
    /// Dịch màn hình: đánh đổi giữa nhanh (Dịch máy Apple trên máy) và hay (AI).
    /// Dịch nhanh (⌃⌥Q): dừng hình lúc chọn vùng và lúc đọc bản dịch.
    @Published var quickFreeze: Bool { didSet { d.set(quickFreeze, forKey: "quickFreeze") } }
    @Published var screenSpeed: ScreenSpeed { didSet { d.set(screenSpeed.rawValue, forKey: "screenSpeed") } }
    @Published var gamepadControls: Bool { didSet { d.set(gamepadControls, forKey: "gamepadControls") } }
    @Published var autoSwitchProfile: Bool { didSet { d.set(autoSwitchProfile, forKey: "autoSwitchProfile") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    @Published var speechVolume: Double { didSet { d.set(speechVolume, forKey: "speechVolume") } }
    @Published var sourceLanguage: String { didSet { d.set(sourceLanguage, forKey: "sourceLanguage") } }
    @Published var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    @Published var groqModel: String { didSet { d.set(groqModel, forKey: "groqModel") } }
    /// Tên model của các dịch vụ thêm sau (Cerebras, Mistral, OpenRouter, dịch vụ tự thêm), theo rawValue của dịch vụ.
    @Published var engineModels: [String: String] { didSet { d.set(engineModels, forKey: "engineModels") } }
    @Published var customEngineName: String { didSet { d.set(customEngineName, forKey: "customEngineName") } }
    @Published var customEngineURL: String { didSet { d.set(customEngineURL, forKey: "customEngineURL") } }
    @Published var customStyle: CustomStyle { didSet { d.set(try? JSONEncoder().encode(customStyle), forKey: "customStyle") } }
    @Published var captureMode: CaptureMode { didSet { d.set(captureMode.rawValue, forKey: "captureMode") } }
    @Published var enginePreference: EnginePreference { didSet { d.set(enginePreference.rawValue, forKey: "enginePreference") } }
    @Published var customOrder: [EngineKind] { didSet { d.set(customOrder.map(\.rawValue).joined(separator: ","), forKey: "customOrder") } }
    @Published var disabledEngines: Set<EngineKind> { didSet { d.set(disabledEngines.map(\.rawValue).joined(separator: ","), forKey: "disabledEngines") } }
    @Published var windowFontSize: Double { didSet { d.set(windowFontSize, forKey: "windowFontSize") } }
    @Published var overlayFit: Bool { didSet { d.set(overlayFit, forKey: "overlayFit") } }
    @Published var targetLanguage: String { didSet { d.set(targetLanguage, forKey: "targetLanguage") } }
    @Published var globalHotkeys: Bool { didSet { d.set(globalHotkeys, forKey: "globalHotkeys") } }
    @Published var menuBarIcon: Bool { didSet { d.set(menuBarIcon, forKey: "menuBarIcon") } }
    /// Ngôn ngữ giao diện: "auto" (theo máy), "vi", "en".
    @Published var appLanguage: String { didSet { d.set(appLanguage, forKey: "appLanguage"); Lang.choice = appLanguage } }
    /// Sáng / tối: "system" (theo máy), "light", "dark".
    @Published var appearance: String { didSet { d.set(appearance, forKey: "appearance"); AppAppearance.apply(appearance) } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var genre: GameGenre { didSet { d.set(genre.rawValue, forKey: "genre") } }
    @Published var smartNames: Bool { didSet { d.set(smartNames, forKey: "smartNames") } }
    @Published var glossary: [GlossaryEntry] {
        didSet { if let data = try? JSONEncoder().encode(glossary) { d.set(data, forKey: "glossary") } }
    }
    @Published var smartSubtitleOnly: Bool { didSet { d.set(smartSubtitleOnly, forKey: "smartSubtitleOnly") } }
    @Published var smartPronouns: Bool { didSet { d.set(smartPronouns, forKey: "smartPronouns") } }
    @Published var contextResetSeconds: Double { didSet { d.set(contextResetSeconds, forKey: "contextResetSeconds") } }
    @Published var ignoreList: [String] { didSet { d.set(ignoreList, forKey: "ignoreList") } }
    @Published var overlayAlign: OverlayAlign { didSet { d.set(overlayAlign.rawValue, forKey: "overlayAlign") } }
    @Published var overlayFollow: Bool { didSet { d.set(overlayFollow, forKey: "overlayFollow") } }
    @Published var overlayFontScale: Double { didSet { d.set(overlayFontScale, forKey: "overlayFontScale") } }
    @Published var overlayDX: Double { didSet { d.set(overlayDX, forKey: "overlayDX") } }
    @Published var overlayDY: Double { didSet { d.set(overlayDY, forKey: "overlayDY") } }
    @Published var overlayWidthPct: Double { didSet { d.set(overlayWidthPct, forKey: "overlayWidthPct") } }
    @Published var autoSpeechRate: Bool { didSet { d.set(autoSpeechRate, forKey: "autoSpeechRate") } }
    /// App nằm dưới vùng chọn lúc Chọn khung (chính là game). Chỉ đọc khi app này ở phía trước, để chuyển Space không đọc nhầm.
    @Published var gameAppName: String? { didSet { d.set(gameAppName, forKey: "gameAppName") } }
    @Published var gameBundleID: String? { didSet { d.set(gameBundleID, forKey: "gameBundleID") } }
    @Published var presets: [Preset] {
        didSet { if let data = try? JSONEncoder().encode(presets) { d.set(data, forKey: "presets") } }
    }
    @Published var activePresetID: UUID? { didSet { d.set(activePresetID?.uuidString, forKey: "activePresetID") } }
    @Published var pauseWhenGameHidden: Bool { didSet { d.set(pauseWhenGameHidden, forKey: "pauseWhenGameHidden") } }
    /// Giữ màn hình luôn sáng (không tắt, không bảo vệ màn hình, không tự khoá) trong lúc OverSub đang chạy.
    @Published var keepScreenAwake: Bool { didSet { d.set(keepScreenAwake, forKey: "keepScreenAwake") } }
    /// Vùng dịch màn hình (tối đa 3): dịch tại chỗ chữ ngoài lời thoại (bảng nhiệm vụ, mô tả vật phẩm...), chạy riêng với phụ đề.
    /// Giữ tên khoá cũ "secondaryRegions" để không mất vùng đã lưu.
    @Published var secondaryRegions: [CaptureRegion] {
        didSet { if let data = try? JSONEncoder().encode(secondaryRegions) { d.set(data, forKey: "secondaryRegions") } }
    }
    @Published var region: CaptureRegion? {
        didSet {
            if let region, let data = try? JSONEncoder().encode(region) {
                d.set(data, forKey: "region")
            } else {
                d.removeObject(forKey: "region")
            }
        }
    }

    private init() {
        mode = DisplayMode(rawValue: d.string(forKey: "mode") ?? "") ?? .viOnly
        overlayEnabled = d.object(forKey: "overlayEnabled") as? Bool ?? true
        style = OverlayStyle(rawValue: d.string(forKey: "style") ?? "") ?? .matchOriginal
        fontSize = d.object(forKey: "fontSize") as? Double ?? 28
        // Bản cũ chỉ có công tắc "đọc thoại": bật nghĩa là vừa phụ đề vừa đọc.
        // Thuyết minh bật sẵn: OverSub ưu tiên vừa xem phụ đề vừa nghe đọc.
        outputMode = OutputMode(rawValue: d.string(forKey: "outputMode") ?? "") ?? .both
        voiceSource = VoiceSource(rawValue: d.string(forKey: "voiceSource") ?? "") ?? .apple
        geminiTTSModel = d.string(forKey: "geminiTTSModel") ?? "gemini-3.8-flash-lite-tts"
        geminiTTSPaid = d.object(forKey: "geminiTTSPaid") as? Bool ?? false
        geminiTTSIntroSeen = d.object(forKey: "geminiTTSIntroSeen") as? Bool ?? false
        geminiMaxWait = d.object(forKey: "geminiMaxWait") as? Double ?? 8
        dubDeviceUID = d.string(forKey: "dubDeviceUID") ?? ""
        duckEnabled = d.object(forKey: "duckEnabled") as? Bool ?? false
        duckLevel = d.object(forKey: "duckLevel") as? Double ?? 0.3
        dropStaleLines = d.object(forKey: "dropStaleLines") as? Bool ?? true
        dubEmotion = d.object(forKey: "dubEmotion") as? Bool ?? true
        cast = (d.data(forKey: "cast").flatMap { try? JSONDecoder().decode([CastMember].self, from: $0) }) ?? []
        contextAutoForget = d.object(forKey: "contextAutoForget") as? Bool ?? false
        dubCharacters = d.object(forKey: "dubCharacters") as? Bool ?? false
        quickAppleTranslation = d.object(forKey: "quickAppleTranslation") as? Bool ?? true
        screenSpeed = ScreenSpeed(rawValue: d.string(forKey: "screenSpeed") ?? "") ?? .balanced
        quickFreeze = d.object(forKey: "quickFreeze") as? Bool ?? true
        screenTranslateEnabled = d.object(forKey: "screenTranslateEnabled") as? Bool ?? true
        gamepadControls = d.object(forKey: "gamepadControls") as? Bool ?? true
        autoSwitchProfile = d.object(forKey: "autoSwitchProfile") as? Bool ?? true
        // Mặc định luôn là giọng tiếng Việt của app, không phụ thuộc "System voice" trong cài đặt hệ thống.
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.5
        speechVolume = d.object(forKey: "speechVolume") as? Double ?? 1.0
        sourceLanguage = d.string(forKey: "sourceLanguage") ?? "en-US"
        // Tên model để đổi được khi Google/Groq đổi tên; mặc định dùng bí danh "latest".
        geminiModel = d.string(forKey: "geminiModel") ?? "gemini-flash-lite-latest"
        groqModel = d.string(forKey: "groqModel") ?? "llama-3.3-70b-versatile"
        engineModels = (d.dictionary(forKey: "engineModels") as? [String: String]) ?? [:]
        customEngineName = d.string(forKey: "customEngineName") ?? ""
        customEngineURL = d.string(forKey: "customEngineURL") ?? ""
        customStyle = CustomStyle.current
        captureMode = CaptureMode.from(d.string(forKey: "captureMode")) ?? .balanced
        enginePreference = EnginePreference(rawValue: d.string(forKey: "enginePreference") ?? "") ?? .balanced
        let savedOrder = (d.string(forKey: "customOrder") ?? "").split(separator: ",").compactMap { EngineKind(rawValue: String($0)) }
        customOrder = savedOrder.isEmpty ? EnginePreference.balanced.order! : EngineKind.completed(savedOrder)
        disabledEngines = Set((d.string(forKey: "disabledEngines") ?? "").split(separator: ",").compactMap { EngineKind(rawValue: String($0)) })
        windowFontSize = d.object(forKey: "windowFontSize") as? Double ?? 28
        overlayFit = d.object(forKey: "overlayFit") as? Bool ?? true
        targetLanguage = d.string(forKey: "targetLanguage") ?? "vi"
        globalHotkeys = d.object(forKey: "globalHotkeys") as? Bool ?? true
        menuBarIcon = d.object(forKey: "menuBarIcon") as? Bool ?? true
        appLanguage = d.string(forKey: "appLanguage") ?? "auto"
        appearance = d.string(forKey: "appearance") ?? "system"
        // Người đã dùng bản trước (đã chọn vùng) thì không cần xem hướng dẫn lần đầu nữa.
        onboardingDone = d.object(forKey: "onboardingDone") as? Bool ?? (d.data(forKey: "region") != nil)
        if ProcessInfo.processInfo.environment["OVERSUB_ONBOARD"] != nil { onboardingDone = false }   // mở lại hướng dẫn để chụp kiểm tra
        genre = GameGenre(rawValue: d.string(forKey: "genre") ?? "") ?? .auto
        smartNames = d.object(forKey: "smartNames") as? Bool ?? true
        glossary = (d.data(forKey: "glossary").flatMap { try? JSONDecoder().decode([GlossaryEntry].self, from: $0) }) ?? []
        smartSubtitleOnly = d.object(forKey: "smartSubtitleOnly") as? Bool ?? true
        smartPronouns = d.object(forKey: "smartPronouns") as? Bool ?? true
        contextResetSeconds = d.object(forKey: "contextResetSeconds") as? Double ?? 45
        ignoreList = d.stringArray(forKey: "ignoreList") ?? []
        overlayAlign = OverlayAlign(rawValue: d.string(forKey: "overlayAlign") ?? "") ?? .auto
        overlayFollow = false   // đã bỏ khỏi giao diện: mỗi câu mới tự đặt đúng chỗ, hiếm game có phụ đề trôi giữa câu
        overlayFontScale = d.object(forKey: "overlayFontScale") as? Double ?? 100
        overlayDX = d.object(forKey: "overlayDX") as? Double ?? 0
        overlayDY = d.object(forKey: "overlayDY") as? Double ?? 0
        overlayWidthPct = d.object(forKey: "overlayWidthPct") as? Double ?? 100
        autoSpeechRate = d.object(forKey: "autoSpeechRate") as? Bool ?? true
        gameAppName = d.string(forKey: "gameAppName")
        gameBundleID = d.string(forKey: "gameBundleID")
        pauseWhenGameHidden = d.object(forKey: "pauseWhenGameHidden") as? Bool ?? true
        keepScreenAwake = d.object(forKey: "keepScreenAwake") as? Bool ?? true
        presets = d.data(forKey: "presets").flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        activePresetID = d.string(forKey: "activePresetID").flatMap(UUID.init(uuidString:))
        // Bản trước chỉ có một vùng phụ ("secondaryRegion").
        secondaryRegions = d.data(forKey: "secondaryRegions").flatMap { try? JSONDecoder().decode([CaptureRegion].self, from: $0) }
            ?? d.data(forKey: "secondaryRegion").flatMap { try? JSONDecoder().decode(CaptureRegion.self, from: $0) }.map { [$0] } ?? []
        if let data = d.data(forKey: "region") {
            region = try? JSONDecoder().decode(CaptureRegion.self, from: data)
        } else {
            region = nil
        }
        ensureDefaultPreset()
        // Bản 1.1 quay về ưu tiên thuyết minh: bật thuyết minh một lần cho người đang dùng, Gemini TTS chuyển sang "đang phát triển".
        if !d.bool(forKey: "voiceOverMigrated") {
            d.set(true, forKey: "voiceOverMigrated")
            if outputMode == .subtitles { outputMode = .both }
            voiceSource = .apple
        }
        // Lỗi cũ: bộ chọn ghi lại giá trị khi vừa hiện làm nhân vật bị đánh dấu "đã chỉnh tay". Gỡ dấu một lần.
        if !d.bool(forKey: "castManualFix1") {
            d.set(true, forKey: "castManualFix1")
            cast = cast.map { var m = $0; m.manual = false; return m }
        }
        // "Chỉ thuyết minh" giờ là hai công tắc: thuyết minh bật, phụ đề đè lên game tắt.
        if outputMode == .dub { outputMode = .both; overlayEnabled = false }
        // Chế độ "Lồng tiếng" thử nghiệm trước đây giờ là "Chỉ thuyết minh" (ẩn phụ đề): đưa về phụ đề + thuyết minh một lần.
        if !d.bool(forKey: "voiceOverMigrated2") {
            d.set(true, forKey: "voiceOverMigrated2")
            outputMode = .both
            for i in presets.indices where presets[i].snapshot.outputMode == OutputMode.dub.rawValue {
                presets[i].snapshot.outputMode = OutputMode.both.rawValue
            }
        }
    }

    /// Công tắc thuyết minh (đọc to bản dịch). Phụ đề đè lên game là công tắc riêng: overlayEnabled.
    var speakEnabled: Bool {
        get { outputMode.speaks }
        set { outputMode = newValue ? .both : .subtitles }
    }
    /// Có hiện phụ đề đè lên không: bật phụ đề đè lên và chế độ đầu ra có phụ đề.
    var overlayActive: Bool { overlayEnabled && outputMode.showsSubtitles }

    var windowShowsOriginal: Bool { mode.showsOriginal }
    var windowShowsTranslation: Bool { mode.translates }
    var target: TargetLanguage { TargetLanguage.find(targetLanguage) }


    /// Câu người dùng đã đặt "luôn bỏ qua" (logo, chữ HUD cố định...). So khớp theo chữ đã chuẩn hoá.
    func isIgnored(_ text: String) -> Bool {
        let n = TextUtil.normalize(text)
        return !n.isEmpty && ignoreList.contains { TextUtil.normalize($0) == n }
    }

    func addIgnored(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isIgnored(t) else { return }
        ignoreList.append(t)
    }

    /// Thêm một thuật ngữ; trùng (không phân biệt hoa thường) thì cập nhật bản dịch.
    func addTerm(_ term: String, translation: String? = nil) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let tr = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = glossary.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            glossary[i].translation = (tr?.isEmpty ?? true) ? nil : tr
        } else {
            glossary.append(GlossaryEntry(term: t, translation: (tr?.isEmpty ?? true) ? nil : tr))
        }
    }

    /// Thêm nhiều dòng một lúc: "Tên" hoặc "Tên = bản dịch". Trả về số mục đã thêm.
    @discardableResult
    func addTerms(fromLines text: String) -> Int {
        var n = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let term = parts.first, !term.isEmpty else { continue }
            addTerm(term, translation: parts.count > 1 ? parts[1] : nil)
            n += 1
        }
        return n
    }

    func model(for e: EngineKind) -> String {
        switch e {
        case .gemini: return geminiModel
        case .groq: return groqModel
        default: return engineModels[e.rawValue] ?? e.defaultModel
        }
    }

    func setModel(_ m: String, for e: EngineKind) {
        switch e {
        case .gemini: geminiModel = m
        case .groq: groqModel = m
        default: engineModels[e.rawValue] = m
        }
    }

    func setEngine(_ e: EngineKind, enabled: Bool) {
        if enabled, disabledEngines.contains(e) { sendToEnd(e) }
        if enabled { disabledEngines.remove(e) } else { disabledEngines.insert(e) }
    }

    /// Dịch vụ mới bật hoặc mới có key: xuống cuối thứ tự tuỳ chỉnh, người dùng muốn ưu tiên thì tự kéo lên.
    func sendToEnd(_ e: EngineKind) {
        guard let i = customOrder.firstIndex(of: e), i != customOrder.count - 1 else { return }
        var order = customOrder
        order.append(order.remove(at: i))
        customOrder = order
    }

    func swapCustom(_ a: EngineKind, with b: EngineKind) {
        guard let i = customOrder.firstIndex(of: a), let j = customOrder.firstIndex(of: b) else { return }
        customOrder.swapAt(i, j)
    }

    func moveCustom(_ e: EngineKind, by delta: Int) {
        guard let i = customOrder.firstIndex(of: e) else { return }
        let j = i + delta
        guard customOrder.indices.contains(j) else { return }
        customOrder.swapAt(i, j)
    }
}

/// Giao diện sáng / tối của app (Cài đặt → Chung). Cửa sổ phụ đề và lớp dịch đè luôn tối, không theo lựa chọn này.
enum AppAppearance {
    @MainActor static func apply(_ choice: String) {
        switch choice {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }
}
