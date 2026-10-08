import AVFoundation
import Foundation

enum Gender: String, Codable, CaseIterable, Identifiable {
    case male, female, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .male: return L("Nam", "Male")
        case .female: return L("Nữ", "Female")
        case .unknown: return L("Chưa rõ", "Unknown")
        }
    }
}

enum AgeGroup: String, Codable, CaseIterable, Identifiable {
    case child, young, adult, elder, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .child: return L("Trẻ em", "Child")
        case .young: return L("Thanh niên", "Young adult")
        case .adult: return L("Trung niên", "Middle-aged")
        case .elder: return L("Người già", "Elderly")
        case .unknown: return L("Chưa rõ", "Unknown")
        }
    }
    var english: String {
        switch self {
        case .child: return "child"
        case .young: return "young"
        case .adult: return "adult"
        case .elder: return "elderly"
        case .unknown: return ""
        }
    }
}

/// Một nhân vật trong dàn diễn viên lồng tiếng. Lưu theo preset, vì mỗi game một dàn nhân vật.
struct CastMember: Codable, Identifiable, Equatable {
    static let narratorID = ""

    var id: String                 // tên đã chuẩn hoá; "" là người dẫn chuyện (câu không có nhãn tên)
    var name: String
    var gender: Gender = .unknown
    var age: AgeGroup = .unknown
    var appleVoice: String?        // VoiceCatalog.siriID hoặc id giọng AVSpeech
    var geminiVoice: String?
    var pitch: Double = 0          // nửa cung, để các nhân vật dùng chung một giọng vẫn nghe khác nhau
    var manual = false             // người dùng đã chỉnh tay: app không tự đổi giọng nữa
    var classified = false         // đã hỏi AI giới tính và tuổi
    var creature: Bool?            // quái vật, robot, sinh vật không phải người: dùng giọng máy (Linh…) thay cho Siri
    var lines = 0

    var isNarrator: Bool { id == Self.narratorID }

    static func key(for name: String) -> String { TextUtil.normalize(name) }
    static var narrator: CastMember {
        CastMember(id: narratorID, name: L("Người dẫn chuyện", "Narrator"), appleVoice: VoiceCatalog.siriID, geminiVoice: "Charon", classified: true)
    }
}

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let gender: Gender
    let detail: String
}

enum VoiceCatalog {
    /// Giọng Siri người dùng chọn cho ngôn ngữ đó trong Cài đặt hệ thống (macOS chỉ cho phát giọng đang được chọn).
    static let siriID = "siri"

    /// Giọng Apple cho một ngôn ngữ: giọng Siri đang chọn, cộng các giọng Apple đã tải (Linh với tiếng Việt).
    static func apple(language base: String, siriGender: Gender) -> [VoiceOption] {
        var out = [VoiceOption(id: siriID, name: L("Siri (giọng bạn chọn trong macOS)", "Siri (the voice you chose in macOS)"), gender: siriGender, detail: "Tự nhiên nhất")]
        var best: [String: AVSpeechSynthesisVoice] = [:]
        for v in AVSpeechSynthesisVoice.speechVoices() where v.language.hasPrefix(base) {
            // Bỏ giọng vui (Bells, Zarvox...) và giọng Eloquence máy móc; chỉ giữ giọng Apple thường.
            guard v.identifier.hasPrefix("com.apple.voice.") else { continue }
            let name = v.name.replacingOccurrences(of: " (Enhanced)", with: "").replacingOccurrences(of: " (Premium)", with: "")
            if let cur = best[name], cur.quality.rawValue >= v.quality.rawValue { continue }
            best[name] = v
        }
        for (name, v) in best.sorted(by: { $0.key < $1.key }) {
            let g: Gender = v.gender == .male ? .male : v.gender == .female ? .female : .unknown
            let q = v.quality == .premium ? "Cao cấp" : v.quality == .enhanced ? "Nâng cao" : "Cơ bản"
            out.append(VoiceOption(id: v.identifier, name: name, gender: g, detail: q))
        }
        return out
    }

    /// 30 giọng dựng sẵn của Gemini TTS. Giới tính theo bộ giọng cùng tên của Google (Chirp 3 HD).
    static let gemini: [VoiceOption] = [
        ("Zephyr", Gender.female, "Sáng"), ("Puck", .male, "Hăng hái"), ("Charon", .male, "Rõ ràng, kể chuyện"),
        ("Kore", .female, "Chắc giọng"), ("Fenrir", .male, "Sôi nổi"), ("Leda", .female, "Trẻ trung"),
        ("Orus", .male, "Chắc giọng"), ("Aoede", .female, "Nhẹ nhàng"), ("Callirrhoe", .female, "Thoải mái"),
        ("Autonoe", .female, "Sáng"), ("Enceladus", .male, "Hơi thở, trầm"), ("Iapetus", .male, "Trong"),
        ("Umbriel", .male, "Thoải mái"), ("Algieba", .male, "Mượt"), ("Despina", .female, "Mượt"),
        ("Erinome", .female, "Trong"), ("Algenib", .male, "Khàn"), ("Rasalgethi", .male, "Rõ ràng"),
        ("Laomedeia", .female, "Hăng hái"), ("Achernar", .female, "Mềm"), ("Alnilam", .male, "Chắc giọng"),
        ("Schedar", .male, "Đều"), ("Gacrux", .female, "Chín chắn"), ("Pulcherrima", .female, "Thẳng thắn"),
        ("Achird", .male, "Thân thiện"), ("Zubenelgenubi", .male, "Bình dân"), ("Vindemiatrix", .female, "Dịu dàng"),
        ("Sadachbia", .male, "Lanh lợi"), ("Sadaltager", .male, "Hiểu biết"), ("Sulafat", .female, "Ấm"),
    ].map { VoiceOption(id: $0.0, name: $0.0, gender: $0.1, detail: $0.2) }

    /// Giọng Gemini hợp tuổi: già thì giọng khàn, chín chắn; trẻ thì giọng sáng, trẻ trung.
    static func geminiPreferred(_ gender: Gender, _ age: AgeGroup) -> [String] {
        switch (gender, age) {
        case (.male, .elder): return ["Algenib", "Enceladus", "Schedar", "Rasalgethi"]
        case (.male, .child), (.male, .young): return ["Puck", "Fenrir", "Sadachbia", "Achird"]
        case (.female, .elder): return ["Gacrux", "Sulafat", "Vindemiatrix"]
        case (.female, .child), (.female, .young): return ["Leda", "Zephyr", "Laomedeia", "Autonoe"]
        default: return []
        }
    }
}

/// Cảm xúc đoán từ câu gốc: dùng để đổi nhịp, cao độ với giọng Apple, và làm chỉ dẫn giọng cho Gemini.
enum Emotion: String {
    case neutral, shout, excited, question, hesitant, laugh, sad

    static func detect(source: String) -> Emotion {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        let letters = s.filter(\.isLetter)
        let upper = letters.filter(\.isUppercase).count
        if lower.contains("haha") || lower.contains("hehe") || lower.contains("heh heh") { return .laugh }
        if (letters.count >= 6 && Double(upper) / Double(letters.count) > 0.7) || s.contains("!!") { return .shout }
        if s.hasSuffix("!") {
            let urgent = ["run", "help", "stop", "no", "watch out", "look out", "get down", "move", "now", "die", "kill"]
            return urgent.contains { lower.contains($0) } ? .shout : .excited
        }
        if s.hasPrefix("...") || s.hasPrefix("…") || s.components(separatedBy: "...").count > 2 || lower.contains("i-i") { return .hesitant }
        let sad = ["sorry", "i miss", "goodbye", "farewell", "forgive me", "it's over", "gone", "dead"]
        if sad.contains(where: { lower.contains($0) }) { return .sad }
        if s.hasSuffix("?") { return .question }
        return .neutral
    }

    /// Điều chỉnh cho giọng Apple: tốc độ (nhân), cao độ (nửa cung), âm lượng (nhân).
    /// Không bao giờ đọc chậm hơn bình thường: câu được đọc sau khi chữ đã hiện xong, kéo dài thêm chỉ làm giọng tụt lại sau game
    /// (người dùng 08/10/2026: "lâu lâu thoại đọc chậm rãi, không cần thiết, tốn thời gian"). Do dự, buồn chỉ hạ cao độ và âm lượng.
    var appleAdjust: (rate: Double, pitch: Double, volume: Double) {
        switch self {
        case .neutral: return (1, 0, 0.92)
        case .question: return (1, 0.5, 0.94)
        case .shout: return (1.12, 1.5, 1)
        case .excited: return (1.06, 1, 1)
        case .hesitant: return (1, -0.5, 0.84)
        case .laugh: return (1.06, 1.2, 1)
        case .sad: return (1, -1.2, 0.85)
        }
    }

    var style: String {
        switch self {
        case .neutral: return "natural conversational tone"
        case .shout: return "shouting urgently, loud and intense"
        case .excited: return "excited, energetic"
        case .question: return "curious, questioning"
        case .hesitant: return "hesitant, unsure, with small pauses"
        case .laugh: return "amused, laughing a little"
        case .sad: return "sad, quiet and heavy"
        }
    }
}

/// Cách đọc một câu: giọng nào, cao độ, tốc độ, âm lượng, chỉ dẫn cảm xúc.
struct VoicePlan: Equatable {
    enum Route: Equatable {
        case siri
        case apple(String)
        case gemini(String)
    }
    var route: Route
    var pitch: Double = 0        // nửa cung
    var rate: Double = 1         // nhân với tốc độ gốc
    var volume: Double = 1       // nhân với âm lượng chung
    var style: String?           // chỉ dẫn giọng cho Gemini
    var fallback: Route = .siri  // khi Gemini hết lượt, lỗi hoặc chậm quá
}

/// Gán giọng cho dàn diễn viên và dựng cách đọc từng câu.
@MainActor
enum CastDirector {
    /// Tự chọn giọng cho nhân vật chưa chỉnh tay: ưu tiên giọng đúng giới tính ít người dùng nhất; giọng phải dùng chung thì đổi cao độ.
    static func autoAssign(_ m: inout CastMember, cast: [CastMember], apple: [VoiceOption]) {
        guard !m.manual, !m.isNarrator else { return }
        let others = cast.filter { $0.id != m.id && !$0.isNarrator }

        if m.creature == true, let robot = apple.first(where: { $0.id != VoiceCatalog.siriID }) {
            // Quái vật, robot: giọng tổng hợp của Apple (Linh…) nghe "máy", kéo trầm xuống cho hợp vai.
            m.appleVoice = robot.id
            let sharing = others.filter { $0.creature == true }.count
            m.pitch = [-4, -6, -2.5, -7][sharing % 4]
        } else {
            // Nhân vật người: luôn dùng giọng Siri (tự nhiên nhất). Phân biệt nhau bằng lệch cao độ nhẹ; lệch nhiều nghe giả.
            m.appleVoice = VoiceCatalog.siriID
            let sharing = others.filter { $0.creature != true && ($0.appleVoice ?? VoiceCatalog.siriID) == VoiceCatalog.siriID }.count
            let offsets: [Double] = [0, 1.5, -1.5, 2.5, -2.5, 3.5, -3.5]
            var p = offsets[sharing % offsets.count]
            if m.age == .child { p += 3 }
            if m.age == .elder { p -= 1.5 }
            // Giọng Siri trên máy là giọng nam mà nhân vật là nữ (hoặc ngược lại) thì kéo cao độ cho đỡ lệch.
            if let g = apple.first(where: { $0.id == VoiceCatalog.siriID })?.gender, g != .unknown, m.gender != .unknown, g != m.gender {
                p += m.gender == .female ? 3 : -3
            }
            m.pitch = max(-6, min(6, p))
        }

        let preferred = VoiceCatalog.geminiPreferred(m.gender, m.age)
        let pool = VoiceCatalog.gemini.filter { m.gender == .unknown || $0.gender == m.gender }
        let ranked = pool.sorted { a, b in
            let ua = others.filter { $0.geminiVoice == a.id }.count, ub = others.filter { $0.geminiVoice == b.id }.count
            if ua != ub { return ua < ub }
            return (preferred.firstIndex(of: a.id) ?? 99) < (preferred.firstIndex(of: b.id) ?? 99)
        }
        m.geminiVoice = ranked.first?.id ?? "Charon"
    }

    static func plan(for m: CastMember, line: String, source: String, voiceSource: VoiceSource, emotion on: Bool,
                     genre: GameGenre, appleAvailable: [VoiceOption]) -> VoicePlan {
        let emotion = on ? Emotion.detect(source: source) : .neutral
        let appleID = m.appleVoice ?? VoiceCatalog.siriID
        let appleRoute: VoicePlan.Route = (appleID == VoiceCatalog.siriID || !appleAvailable.contains { $0.id == appleID })
            ? .siri : .apple(appleID)
        let adj = emotion.appleAdjust
        // Cảm xúc chỉ đổi tốc độ và âm lượng (Siri làm được khi đọc thẳng); đổi cao độ buộc phải dựng trước, trễ thêm khoảng 1 giây.
        // Giọng đã phải dựng trước (có lệch cao độ, hoặc giọng Apple khác) thì cảm xúc đổi được cả cao độ; giọng Siri đọc thẳng
        // thì chỉ đổi tốc độ và âm lượng để giữ độ trễ thấp nhất.
        let rendered = abs(m.pitch) >= 0.25 || appleRoute != .siri
        var plan = VoicePlan(route: appleRoute, pitch: m.pitch + (rendered ? adj.pitch : 0), rate: adj.rate, volume: adj.volume)
        plan.fallback = appleRoute
        if voiceSource == .gemini {
            var who: [String] = []
            if !m.age.english.isEmpty { who.append(m.age.english) }
            if m.gender != .unknown { who.append(m.gender == .male ? "man" : "woman") }
            let person = who.isEmpty ? (m.isNarrator ? "narrator" : "character") : who.joined(separator: " ")
            plan.route = .gemini(m.geminiVoice ?? "Charon")
            plan.pitch = 0; plan.rate = 1; plan.volume = 1
            plan.style = "\(person); \(emotion.style); \(genre.englishHint.prefix(90))"
        }
        return plan
    }
}
