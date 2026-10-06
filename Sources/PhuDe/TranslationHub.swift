import Foundation
import SwiftUI

struct KeyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var provider: EngineKind          // .gemini hoặc .groq
    var secret: String
    var addedAt = Date()

    var masked: String { secret.count > 10 ? "\(secret.prefix(4))…\(secret.suffix(4))" : "••••" }
}

/// Key lưu ở một file riêng của app, chỉ tài khoản người dùng đọc được (0600).
/// Không dùng Keychain: app ký kiểu ad-hoc nên mỗi lần build lại, macOS lại coi là app mới và hỏi mật khẩu đăng nhập.
enum KeyFile {
    static var url: URL {
        AppPaths.support.appendingPathComponent("keys.json")
    }

    static func load() -> [KeyEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([KeyEntry].self, from: data)
    }

    static func save(_ keys: [KeyEntry]) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Trạng thái chạy của từng key, không phải bí mật nên lưu ở UserDefaults.
struct KeyRuntime: Codable {
    var usedToday = 0
    var day = ""
    var cooldownUntil: Date?
    var cooldownReason: String?
    var invalidReason: String?
    var remaining: Int?               // Groq trả về số lượt còn lại trong header
    var limit: Int?
}

struct TranslationOutcome {
    var text: String
    var engine: EngineKind
    var label: String
    var ms: Double
}

@MainActor
final class TranslationHub: ObservableObject {
    enum Health { case unknown, good, degraded, down, off }

    struct Sample: Codable { var ok: Bool; var ms: Double }
    struct Stats: Codable {
        var recent: [Sample] = []
        var usedToday = 0
        var day = ""
        var lastError: String?
        var downUntil: Date?
        var consecutiveFailures = 0
    }
    struct LogEntry: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let resumeAt: Date?
    }

    @Published private(set) var keys: [KeyEntry] = []
    @Published private(set) var runtime: [UUID: KeyRuntime] = [:]
    @Published private(set) var stats: [EngineKind: Stats] = [:]
    @Published private(set) var log: [LogEntry] = []
    @Published var activeLabel = L("Chưa có câu nào", "No lines yet")
    @Published var activeOK = false   // câu gần nhất dịch được (chấm xanh ở cửa sổ chính)
    @Published private(set) var benchmarking = false

    private let settings: AppSettings
    private var cursor: [EngineKind: Int] = [:]
    private let defaults = UserDefaults.standard

    init(settings: AppSettings) {
        self.settings = settings
        loadKeys()
    }

    // MARK: Lưu trữ

    private func loadKeys() {
        if let list = KeyFile.load() {
            keys = list
        } else if !defaults.bool(forKey: "keysFileMigrated") {
            // Chuyển một lần từ Keychain (bản cũ) sang file. Sau lần này app không đụng tới Keychain nữa.
            if let data = Keychain.get("keys").data(using: .utf8), let list = try? JSONDecoder().decode([KeyEntry].self, from: data) {
                keys = list
            }
            for (account, provider) in [("gemini", EngineKind.gemini), ("groq", .groq)] {
                for k in parseKeys(Keychain.get(account)) where !keys.contains(where: { $0.secret == k }) {
                    keys.append(KeyEntry(provider: provider, secret: k))
                }
            }
            defaults.set(true, forKey: "keysFileMigrated")
            if !keys.isEmpty { saveKeys() }
        }
        if let data = defaults.data(forKey: "keyRuntime"), let r = try? JSONDecoder().decode([UUID: KeyRuntime].self, from: data) {
            runtime = r
        }
        // Số đo tốc độ và độ ổn định giữ qua các lần mở app, để thứ tự tự động không phải đo lại từ đầu.
        if let data = defaults.data(forKey: "engineStats"), let raw = try? JSONDecoder().decode([String: Stats].self, from: data) {
            for (k, v) in raw { if let e = EngineKind(rawValue: k) { stats[e] = v } }
        }
    }

    private func saveStats() {
        let raw = Dictionary(uniqueKeysWithValues: stats.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: "engineStats") }
    }

    private func saveKeys() { KeyFile.save(keys) }

    private func saveRuntime() {
        if let data = try? JSONEncoder().encode(runtime) { defaults.set(data, forKey: "keyRuntime") }
    }

    func warmUp() {
        let source = SourceLanguage.find(settings.sourceLanguage).code
        let target = settings.target.code
        Task.detached { await Providers.warmUp(source: source, target: target) }
    }

    // MARK: Key

    func keys(for engine: EngineKind) -> [KeyEntry] { keys.filter { $0.provider == engine } }

    func removeKey(_ id: UUID) {
        keys.removeAll { $0.id == id }
        runtime[id] = nil
        saveKeys(); saveRuntime()
    }

    /// Hỏi nhà cung cấp tài khoản này dùng được model nào và đổi sang model phù hợp. Trả về tên model mới nếu đã đổi.
    private func repairModel(_ engine: EngineKind, key: String) async -> String? {
        guard let models = try? await Providers.listModels(engine, key: key),
              let pick = Providers.pickModel(engine, from: models) else { return nil }
        let old = settings.model(for: engine)
        guard pick != old else { return nil }
        settings.setModel(pick, for: engine)
        note(L("\(engine.title): model \"\(old)\" không dùng được với tài khoản này, đã tự đổi sang \"\(pick)\".",
               "\(engine.title): model \"\(old)\" isn't available on this account, switched to \"\(pick)\"."))
        return pick
    }

    /// Kiểm tra key bằng một lượt dịch thật; chỉ thêm vào danh sách khi key hoạt động.
    func addKey(_ provider: EngineKind, secret raw: String) async -> (ok: Bool, message: String) {
        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return (false, L("Chưa dán key.", "Paste an API key first.")) }
        if keys.contains(where: { $0.secret == secret }) { return (false, L("Key này đã có trong danh sách.", "This key is already in the list.")) }
        if provider == .custom, provider.baseURL.isEmpty { return (false, L("Nhập địa chỉ API của dịch vụ trước.", "Enter the service's API address first.")) }
        let system = Providers.systemPrompt(source: "tiếng Anh")
        let user = "Câu cần dịch:\nHello, how are you?"
        let t0 = Date()

        func accept(_ r: ProviderResult?, cooldown: (until: Date, reason: String)? = nil) -> KeyEntry {
            let entry = KeyEntry(provider: provider, secret: secret)
            if keys(for: provider).isEmpty { settings.sendToEnd(provider) }   // dịch vụ mới: xuống cuối thứ tự tuỳ chỉnh
            keys.append(entry)
            if let r { applyRemaining(entry.id, r) }
            if let c = cooldown {
                runtime[entry.id, default: KeyRuntime()].cooldownUntil = c.until
                runtime[entry.id, default: KeyRuntime()].cooldownReason = c.reason
            }
            saveKeys(); saveRuntime()
            return entry
        }

        do {
            var repaired: String?
            var result: ProviderResult
            do {
                result = try await callProvider(provider, key: secret, system: system, user: user)
            } catch Failure.unavailable {
                // Key được nhận nhưng model đặt sẵn không dùng được: hỏi tài khoản xem dùng được model nào.
                guard let pick = await repairModel(provider, key: secret) else {
                    // Gọi được danh sách model nghĩa là key hợp lệ; chỉ là không chọn được model.
                    if (try? await Providers.listModels(provider, key: secret)) != nil {
                        _ = accept(nil)
                        return (true, L("Key hợp lệ và đã thêm, nhưng app chưa chọn được model phù hợp. Vào Engine dịch → Nâng cao để nhập tên model.", "The key is valid and was added, but the app couldn't pick a suitable model. Go to Translation services → Advanced to enter a model name."))
                    }
                    return (false, L("Key được nhận nhưng không dùng được model nào để dịch.", "The key was accepted, but no model is available for translation."))
                }
                repaired = pick
                result = try await callProvider(provider, key: secret, system: system, user: user)
            }
            guard !result.text.isEmpty else { return (false, L("Key được nhận nhưng không có nội dung trả về, thử lại sau.", "The key was accepted but nothing came back. Try again later.")) }
            let entry = accept(result)
            let ms = Date().timeIntervalSince(t0) * 1000
            // Lượt kiểm tra cũng là một lần dịch thật: ghi vào số liệu để trạng thái engine hiện ngay, không còn "chưa dùng".
            recordSuccess(provider, ms: ms, key: entry, result: result)
            // Lượt đầu còn tính cả thời gian mở kết nối: đo thêm hai lượt để có số tốc độ đáng tin cho việc tự sắp thứ tự.
            for _ in 0..<2 {
                let t = Date()
                guard let r = try? await callProvider(provider, key: secret, system: system, user: user), !r.text.isEmpty else { break }
                recordSuccess(provider, ms: Date().timeIntervalSince(t) * 1000, key: entry, result: r)
            }
            var msg = String(format: L("Key hoạt động (khoảng %.0f ms mỗi câu). Đã thêm vào danh sách.", "Key works (about %.0f ms per line). Added to the list."), typicalMs(provider))
            if let repaired { msg += L(" Model cũ không còn dùng được nên app đã tự đổi sang \(repaired).", " The old model is no longer available, so the app switched to \(repaired).") }
            return (true, msg)
        } catch let f as Failure {
            switch f {
            case .rateLimit(let until, _, let reason):
                _ = accept(nil, cooldown: (until, reason))
                return (true, L("Key hợp lệ nhưng đang hết hạn mức (\(reason)). Đã thêm, app sẽ tự dùng lại sau \(Self.human(until.timeIntervalSinceNow)).", "The key is valid but out of quota (\(reason)). Added; the app will use it again in \(Self.human(until.timeIntervalSinceNow))."))
            case .invalidKey(let m): return (false, L("Key không hợp lệ: \(m)", "Invalid key: \(m)"))
            default: return (false, L("Chưa kiểm tra được, key chưa được thêm: \(f.message)", "Couldn't verify, so the key wasn't added: \(f.message)"))
            }
        } catch {
            return (false, L("Chưa kiểm tra được: \(error.localizedDescription)", "Couldn't verify: \(error.localizedDescription)"))
        }
    }

    private func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func model(for engine: EngineKind) -> String { settings.model(for: engine) }

    private func callProvider(_ engine: EngineKind, key: String, system: String, user: String, maxTokens: Int = 256,
                              onPartial: (@MainActor (String) -> Void)? = nil) async throws -> ProviderResult {
        switch engine {
        case .gemini: return try await Providers.gemini(key: key, model: settings.geminiModel, system: system, user: user, maxTokens: maxTokens, onPartial: onPartial)
        case .groq, .cerebras, .mistral, .openRouter, .custom:
            return try await Providers.openAI(engine, key: key, model: settings.model(for: engine), system: system, user: user, maxTokens: maxTokens, onPartial: onPartial)
        default: throw Failure.unavailable(L("Engine này không dùng key.", "This engine doesn't use an API key."))
        }
    }

    private func isUsable(_ k: KeyEntry, now: Date = Date()) -> Bool {
        let r = runtime[k.id]
        if r?.invalidReason != nil { return false }
        if let until = r?.cooldownUntil, until > now { return false }
        return true
    }

    private func usableKeys(_ engine: EngineKind) -> [KeyEntry] {
        let list = keys(for: engine).filter { isUsable($0) }
        guard !list.isEmpty else { return [] }
        // Xoay vòng để chia đều lượt dùng giữa các key.
        let start = cursor[engine, default: 0] % list.count
        cursor[engine] = start + 1
        return Array(list[start...] + list[..<start])
    }

    private func applyRemaining(_ id: UUID, _ r: ProviderResult) {
        if let rem = r.remaining { runtime[id, default: KeyRuntime()].remaining = rem }
        if let lim = r.limit { runtime[id, default: KeyRuntime()].limit = lim }
    }

    /// Hỏi AI một câu ngắn (vd. đoán giới tính, tuổi nhân vật). Thử Groq, Gemini theo key còn dùng được, cuối cùng Apple Intelligence.
    /// Không ghi vào số liệu dịch.
    func ask(system: String, user: String) async -> String? {
        let online = EngineKind.allCases.filter { $0.needsKey && !keys(for: $0).isEmpty }.sorted { typicalMs($0) < typicalMs($1) }
        for engine in online where !settings.disabledEngines.contains(engine) {
            for k in usableKeys(engine).prefix(2) {
                if let r = try? await callProvider(engine, key: k.secret, system: system, user: user) {
                    applyRemaining(k.id, r)
                    return Providers.clean(r.text)
                }
            }
        }
        if !settings.disabledEngines.contains(.appleAI), let t = try? await Providers.appleAI(system: system, user: user, targetCode: "en") {
            return Providers.clean(t)
        }
        return nil
    }

    /// Dịch màn hình: dịch nhiều cụm chữ giao diện trong một lần gọi, trả về đúng số cụm theo thứ tự.
    /// `fast`: thử Groq trước (thường dưới một giây); không thì theo thứ tự engine người dùng chọn. nil nếu không engine nào trả lời đúng dạng.
    func translateUI(_ items: [String], source: SourceLanguage, fast: Bool) async -> (texts: [String], label: String)? {
        guard !items.isEmpty else { return ([], "") }
        // Menu dài: chia lô 12 dòng để câu trả lời không bị cắt giữa chừng; các lô chạy song song.
        let chunks = stride(from: 0, to: items.count, by: 12).map { Array(items[$0..<min($0 + 12, items.count)]) }
        if chunks.count > 1 {
            var parts = [[String]?](repeating: nil, count: chunks.count), label = ""
            await withTaskGroup(of: (Int, (texts: [String], label: String)?).self) { group in
                for (n, c) in chunks.enumerated() { group.addTask { (n, await self.translateUI(c, source: source, fast: fast)) } }
                for await (n, r) in group { parts[n] = r?.texts; if let r { label = r.label } }
            }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return (parts.flatMap { $0! }, label)
        }
        let target = settings.target
        let system = ScreenText.systemPrompt(source: target.isVietnamese ? source.name : source.english, target: target)
        var terms: [GlossaryEntry] = []
        if settings.smartNames {
            for t in items { for e in Glossary.matches(in: t, entries: settings.glossary) where !terms.contains(e) { terms.append(e) } }
        }
        let user = ScreenText.userPrompt(items, terms: terms)
        // Bản dịch tiếng Việt dài hơn gốc; chừa dư để không bị cắt.
        let maxTokens = min(2048, max(320, items.reduce(0) { $0 + $1.count } + items.count * 12))
        var order = candidateOrder().filter { $0.needsKey || $0 == .appleAI }
        // Cần nhanh: dịch vụ qua mạng có độ trễ đo được thấp nhất đi trước.
        if fast, let quickest = order.filter(\.needsKey).min(by: { typicalMs($0) < typicalMs($1) }), let g = order.firstIndex(of: quickest) {
            order.insert(order.remove(at: g), at: 0)
        }
        // Đi qua cùng đường với dịch phụ đề: key hết hạn mức thì tạm nghỉ, key sai thì loại, có ghi số liệu.
        for engine in order where unavailableReason(engine) == nil {
            guard let out = try? await attempt(engine, text: "", system: system, user: user, source: source, maxTokens: maxTokens),
                  let lines = ScreenText.parseNumbered(out.text, count: items.count) else { continue }
            // "=": không cần dịch, trả lại chữ gốc để không thay chữ đó trên màn hình.
            return (zip(lines, items).map { $0.0.trimmingCharacters(in: .whitespaces) == "=" ? $0.1 : $0.0 }, engine.title)
        }
        return nil
    }

    // MARK: Dịch

    /// `onPartial`: nhận bản dịch đang dài dần (theo luồng, chỉ Gemini và Groq) để hiện và đọc câu đầu sớm hơn.
    func translate(_ text: String, context: [ContextLine], source: SourceLanguage, speaker: String? = nil, fragment: Bool = false,
                   classify: Bool = true, onPartial: (@MainActor (String) -> Void)? = nil) async throws -> TranslationOutcome {
        let smartOn = settings.smartSubtitleOnly || settings.smartPronouns
        let names = settings.smartNames
        // Thuật ngữ trong từ điển có mặt trong câu này (chỉ những mục liên quan, để tiết kiệm token).
        let hits = names ? Glossary.matches(in: text, entries: settings.glossary) : []
        var failed: [(EngineKind, String)] = []

        var engines: [EngineKind] = []
        for engine in candidateOrder() {
            if let reason = unavailableReason(engine) { failed.append((engine, reason)) } else { engines.append(engine) }
        }

        // Dịch bằng một engine: lời nhắc phù hợp, bảo vệ thuật ngữ bằng mã tạm, nhận dấu "không phải lời thoại".
        let run: (EngineKind, @escaping @MainActor (String) -> Void) async throws -> TranslationOutcome = { [weak self] engine, partial in
            guard let self else { throw CancellationError() }
            // Bảo vệ thuật ngữ bằng mã tạm cho engine giữ được mã; Apple Intelligence làm mất mã nên dịch câu gốc.
            var protected: Glossary.Protected?
            var input = text
            if !hits.isEmpty, engine.keepsPlaceholders {
                let p = Glossary.protect(text, entries: hits)
                if !p.isEmpty { protected = p; input = p.text }
            }
            // Lời nhắc cơ bản cho engine không làm theo được chỉ dẫn phức tạp (Apple); lời nhắc thông minh cho Gemini và Groq.
            let smart = smartOn && engine.supportsSmartPrompt
            let target = self.settings.target
            let sourceName = target.isVietnamese ? source.name : source.english
            let system = smart
                ? Providers.smartSystemPrompt(source: sourceName, filter: self.settings.smartSubtitleOnly && classify, pronouns: self.settings.smartPronouns,
                                              genre: self.settings.genre, names: names, usesCodes: protected != nil, target: target)
                : Providers.systemPrompt(source: sourceName, target: target)
            let user = smart
                ? Providers.smartUserPrompt(input, context: context, speaker: speaker, fragment: fragment, target: target)
                : Providers.userPrompt(input, context: context.map { ($0.source, $0.vi) }, fragment: fragment, target: target)

            // Bản dịch đang dài dần: bỏ phần suy nghĩ của model, chưa hiện khi có thể là dấu "không phải lời thoại", trả lại tên riêng.
            var forward: (@MainActor (String) -> Void)?
            if onPartial != nil {
                let codes = protected
                forward = { raw in
                    guard var t = TranslationHub.visiblePartial(raw) else { return }
                    if let p = codes { t = Glossary.restore(TranslationHub.dropTrailingCode(t), p).text }
                    partial(t)
                }
            }
            var outcome = try await self.attempt(engine, text: input, system: system, user: user, source: source, onPartial: forward)
            if smart && (outcome.text.contains("BỎ QUA") || outcome.text.contains("[SKIP]")) { outcome.text = "" }   // AI báo đây không phải lời thoại
            if let p = protected, !outcome.text.isEmpty {
                let r = Glossary.restore(outcome.text, p)
                outcome.text = r.text
                if r.lost > 0 { self.note(L("\(engine.title) làm mất \(r.lost) mã tên riêng; bản dịch này có thể đã dịch tên.", "\(engine.title) dropped \(r.lost) name placeholders; names in this line may have been translated.")) }
            }
            return outcome
        }

        // Thử theo cặp: engine đầu chưa trả lời sau 2,5 giây (hoặc lỗi sớm hơn) thì gửi luôn cho engine kế tiếp, lấy kết quả về trước.
        var i = 0
        while i < engines.count {
            let a = engines[i]
            let b = i + 1 < engines.count ? engines[i + 1] : nil
            let r = await Hedge(run: run, onPartial: onPartial).start(a, backup: b, after: Self.hedgeDelay)
            failed += r.failures
            if let outcome = r.outcome {
                if r.backupWon { DebugLog.write("Dịch: \(a.title) chưa trả lời sau \(Self.hedgeDelay) giây, dùng kết quả của \(outcome.label)") }
                if let first = failed.first {
                    note(L("\(first.0.title) không dịch được (\(first.1)). Đã chuyển sang \(outcome.label).", "\(first.0.title) couldn't translate (\(first.1)). Switched to \(outcome.label)."))
                }
                activeLabel = "\(outcome.label) · \(Int(outcome.ms)) ms"
                activeOK = true
                return outcome
            }
            i += b == nil ? 1 : 2
        }
        let summary = failed.map { "\($0.0.title): \($0.1)" }.joined(separator: "; ")
        activeLabel = L("Không dịch vụ nào dịch được", "No service could translate")
        activeOK = false
        throw AppError(summary.isEmpty ? L("Chưa bật engine dịch nào. Vào Cài đặt → Dịch vụ dịch.", "No translation engine is turned on. Go to Settings → Translation services.") : summary)
    }

    /// Dịch vụ đầu chưa ra chữ nào sau 1 giây thì gửi song song cho dịch vụ kế tiếp, ai ra chữ trước thì dùng.
    /// Đo thực tế: Gemini trung vị 1,0 giây nhưng 15% số câu hơn 2 giây; Groq trung vị 0,34 giây. Chờ 2,5 giây như trước
    /// thì các câu Gemini chậm bị trễ rõ.
    static let hedgeDelay = 1.0

    /// Phần hiện được của bản dịch đang dài dần: bỏ khối <think> của model suy luận; câu mở đầu bằng "[" có thể là dấu bỏ qua nên chờ thêm.
    nonisolated static func visiblePartial(_ raw: String) -> String? {
        var t = raw
        if let open = t.range(of: "<think>") {
            guard let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) else { return nil }
            t = String(t[close.upperBound...])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains("BỎ QUA") || t.contains("[SKIP]") { return nil }
        if t.hasPrefix("["), t.count < 12 { return nil }
        return t
    }

    /// Mã tạm của thuật ngữ (Xqza...) có thể đang dở ở cuối chuỗi: cắt đi để không hiện mã lên màn hình.
    nonisolated static func dropTrailingCode(_ t: String) -> String {
        guard let last = t.split(separator: " ").last, last.hasPrefix("X"), last.count <= 4, "Xqz".hasPrefix(last.prefix(3)) else { return t }
        return String(t.dropLast(last.count)).trimmingCharacters(in: .whitespaces)
    }

    private func attempt(_ engine: EngineKind, text: String, system: String, user: String, source: SourceLanguage,
                         maxTokens: Int = 256, onPartial: (@MainActor (String) -> Void)? = nil) async throws -> TranslationOutcome {
        if !engine.needsKey {
            let t0 = Date()
            do {
                let out: String
                if engine == .appleAI {
                    out = try await Providers.appleAI(system: system, user: user, targetCode: settings.target.code)
                } else {
                    out = try await Providers.appleTranslate(text, source: source.code, target: settings.target.code)
                }
                let ms = Date().timeIntervalSince(t0) * 1000
                recordSuccess(engine, ms: ms)
                return TranslationOutcome(text: Providers.clean(out), engine: engine, label: engine.title, ms: ms)
            } catch let f as Failure {
                recordFailure(engine, f)
                throw f
            }
        }

        let candidates = usableKeys(engine)
        var last: Failure = .unavailable(L("không có key", "no API key"))
        for k in candidates {
            let t0 = Date()
            do {
                let r: ProviderResult
                do {
                    r = try await callProvider(engine, key: k.secret, system: system, user: user, maxTokens: maxTokens, onPartial: onPartial)
                } catch Failure.unavailable {
                    // Model đã bị đổi tên hoặc tài khoản không còn quyền: tự chọn model khác một lần rồi thử lại.
                    guard await repairModel(engine, key: k.secret) != nil else { throw Failure.unavailable(L("model không dùng được và không tìm được model thay thế", "model unavailable and no replacement found")) }
                    r = try await callProvider(engine, key: k.secret, system: system, user: user, maxTokens: maxTokens)
                }
                let ms = Date().timeIntervalSince(t0) * 1000
                // Lô chữ dài của dịch màn hình mất lâu hơn một câu thoại: không tính vào số đo tốc độ.
                recordSuccess(engine, ms: ms, key: k, result: r, sample: maxTokens <= 256)
                return TranslationOutcome(text: Providers.clean(r.text), engine: engine,
                                          label: "\(engine.title) (key \(k.masked))", ms: ms)
            } catch let f as Failure {
                last = f
                switch f {
                case .rateLimit(let until, _, let reason):
                    runtime[k.id, default: KeyRuntime()].cooldownUntil = until
                    runtime[k.id, default: KeyRuntime()].cooldownReason = reason
                    saveRuntime()
                    note(L("\(engine.title) key \(k.masked) tạm ngưng: \(reason). Dùng lại sau \(Self.human(until.timeIntervalSinceNow)).", "\(engine.title) key \(k.masked) paused: \(reason). Back in \(Self.human(until.timeIntervalSinceNow))."), resumeAt: until)
                    continue   // thử key kế tiếp của cùng engine
                case .invalidKey(let m):
                    runtime[k.id, default: KeyRuntime()].invalidReason = m
                    saveRuntime()
                    note(L("\(engine.title) key \(k.masked) bị loại: \(m).", "\(engine.title) key \(k.masked) removed from rotation: \(m)."))
                    continue
                case .refused:
                    throw f   // nội dung bị từ chối, đổi key cũng vô ích
                default:
                    recordFailure(engine, f)
                    throw f   // quá tải, sai model, mất mạng: sang engine khác
                }
            }
        }
        throw last
    }

    // MARK: Sức khoẻ

    private func recordSuccess(_ engine: EngineKind, ms: Double, key: KeyEntry? = nil, result: ProviderResult? = nil, sample: Bool = true) {
        var s = stats[engine, default: Stats()]
        if s.day != today() { s.day = today(); s.usedToday = 0 }
        s.usedToday += 1
        if sample {
            s.recent.append(Sample(ok: true, ms: ms))
            if s.recent.count > 20 { s.recent.removeFirst() }
        }
        s.consecutiveFailures = 0
        s.downUntil = nil
        stats[engine] = s
        saveStats()
        if let k = key {
            var r = runtime[k.id, default: KeyRuntime()]
            if r.day != today() { r.day = today(); r.usedToday = 0 }
            r.usedToday += 1
            runtime[k.id] = r
            if let result { applyRemaining(k.id, result) }
            if let rem = runtime[k.id]?.remaining, let lim = runtime[k.id]?.limit, lim > 0, Double(rem) / Double(lim) < 0.05 {
                note(L("\(engine.title) key \(k.masked) sắp hết lượt trong ngày: còn \(rem)/\(lim).", "\(engine.title) key \(k.masked) is almost out of requests for today: \(rem)/\(lim) left."))
            }
            saveRuntime()
        }
    }

    private func recordFailure(_ engine: EngineKind, _ f: Failure) {
        var s = stats[engine, default: Stats()]
        s.recent.append(Sample(ok: false, ms: 0))
        if s.recent.count > 20 { s.recent.removeFirst() }
        s.consecutiveFailures += 1
        s.lastError = f.message
        var pause: TimeInterval = 0
        if case .unavailable = f { pause = 300 }                     // sai cấu hình, không nên thử lại liên tục
        else if s.consecutiveFailures >= 3 { pause = 120 }           // lỗi liên tục
        if pause > 0 {
            s.downUntil = Date().addingTimeInterval(pause)
            note(L("\(engine.title) tạm ngưng \(Self.human(pause)): \(f.message)", "\(engine.title) paused for \(Self.human(pause)): \(f.message)"), resumeAt: s.downUntil)
        }
        stats[engine] = s
        saveStats()
    }

    func health(_ engine: EngineKind, now: Date = Date()) -> Health {
        if settings.disabledEngines.contains(engine) { return .off }
        let s = stats[engine] ?? Stats()
        if let until = s.downUntil, until > now { return .down }
        let samples = s.recent
        guard samples.count >= 3 else { return .unknown }
        let ok = samples.filter(\.ok)
        let rate = Double(ok.count) / Double(samples.count)
        let avg = ok.isEmpty ? 0 : ok.map(\.ms).reduce(0, +) / Double(ok.count)
        let slow = engine.needsKey ? 3500.0 : 5000.0
        return (rate < 0.7 || avg > slow) ? .degraded : .good
    }

    /// Engine nào đang chưa dùng được và vì sao (nil nếu dùng được).
    func unavailableReason(_ engine: EngineKind, now: Date = Date()) -> String? {
        if let until = stats[engine]?.downUntil, until > now {
            let why = stats[engine]?.lastError ?? L("lỗi liên tục", "repeated errors")
            return L("tạm ngưng (\(why)), thử lại sau \(Self.human(until.timeIntervalSince(now)))",
                     "paused (\(why)), retrying in \(Self.human(until.timeIntervalSince(now)))")
        }
        if engine.needsKey {
            let all = keys(for: engine)
            if all.isEmpty { return L("chưa có key", "no API key yet") }
            if !all.contains(where: { isUsable($0, now: now) }) {
                let waits = all.compactMap { runtime[$0.id]?.cooldownUntil }.filter { $0 > now }
                if let soonest = waits.min() { return L("mọi key đang hết hạn mức, dùng lại sau \(Self.human(soonest.timeIntervalSince(now)))", "all keys are out of quota, back in \(Self.human(soonest.timeIntervalSince(now)))") }
                return L("mọi key đều không hợp lệ", "all keys are invalid")
            }
        }
        return nil
    }

    /// Độ trễ điển hình của engine: trung vị các lần dịch gần đây (một lần chậm bất thường không làm lệch),
    /// cộng phạt theo tỉ lệ lỗi để dịch vụ hay hỏng không được xếp trên dịch vụ ổn định. Chưa có số liệu thì dùng ước lượng.
    func typicalMs(_ e: EngineKind) -> Double {
        let recent = stats[e]?.recent ?? []
        let ok = recent.filter(\.ok).map(\.ms).sorted()
        if !ok.isEmpty {
            let median = ok[ok.count / 2]
            let failRate = Double(recent.count - ok.count) / Double(recent.count)
            return median * (1 + 2 * failRate)
        }
        switch e {
        case .groq: return 500            // đo thực: Qwen ~250 ms, gpt-oss ~600 ms
        case .cerebras: return 500
        case .mistral: return 700
        case .gemini: return 900          // đo thực: 0.7 đến 1.3 giây
        case .custom: return 1000
        case .openRouter: return 1500     // model miễn phí thường phải xếp hàng
        case .appleTranslation: return 1200
        case .appleAI: return 1800        // đo thực: 1.2 đến 3.7 giây
        }
    }

    /// Dịch vụ đã sẵn sàng để xét thứ tự: chạy trên máy, hoặc đã có key.
    private func configured(_ e: EngineKind) -> Bool { !e.needsKey || !keys(for: e).isEmpty }

    /// Thứ tự thử theo chế độ ưu tiên đã chọn. Ưu tiên tốc độ và cân bằng dùng độ trễ đo thực tế ở bảng trạng thái.
    func currentOrder() -> [EngineKind] {
        let quality = EngineKind.byQuality.filter(configured)
        let bySpeed = quality.sorted { typicalMs($0) < typicalMs($1) }
        let order: [EngineKind]
        switch settings.enginePreference {
        case .quality: order = quality
        case .speed: order = bySpeed
        case .custom: order = settings.customOrder.filter(configured)
        case .balanced:
            func score(_ e: EngineKind) -> Int { quality.firstIndex(of: e)! + bySpeed.firstIndex(of: e)! }
            order = quality.sorted {
                score($0) != score($1) ? score($0) < score($1) : quality.firstIndex(of: $0)! < quality.firstIndex(of: $1)!
            }
        }
        var result = order.filter { !settings.disabledEngines.contains($0) }
        // Dịch máy Apple không nhận chỉ dẫn (bỏ chữ giao diện, giữ xưng hô): để cuối cùng, trừ khi người dùng tự sắp xếp.
        if settings.enginePreference != .custom, settings.smartSubtitleOnly || settings.smartPronouns,
           let i = result.firstIndex(of: .appleTranslation) {
            result.append(result.remove(at: i))
        }
        return result
    }

    /// Đo lại tốc độ: gửi hai câu ngắn tới từng dịch vụ đang có key dùng được, các dịch vụ chạy song song.
    func benchmark() async {
        guard !benchmarking else { return }
        benchmarking = true
        defer { benchmarking = false }
        let system = Providers.systemPrompt(source: "tiếng Anh", target: settings.target)
        let user = Providers.userPrompt("We should leave before the storm gets here.", context: [], fragment: false, target: settings.target)
        let source = SourceLanguage.find("en-US")
        let engines = EngineKind.allCases.filter { $0.needsKey && !settings.disabledEngines.contains($0) && unavailableReason($0) == nil }
        await withTaskGroup(of: Void.self) { group in
            for e in engines {
                group.addTask { @MainActor in
                    for _ in 0..<2 {
                        guard (try? await self.attempt(e, text: "", system: system, user: user, source: source)) != nil else { break }
                    }
                }
            }
        }
        note(L("Đã đo lại tốc độ: " + engines.map { "\($0.title) \(Int(typicalMs($0))) ms" }.joined(separator: ", "),
               "Speed re-measured: " + engines.map { "\($0.title) \(Int(typicalMs($0))) ms" }.joined(separator: ", ")))
    }

    /// Ghi một dòng vào nhật ký (cho phần Engine dùng khi đặt lại ngữ cảnh).
    func logEvent(_ text: String) { note(text) }

    private func candidateOrder() -> [EngineKind] {
        let order = currentOrder()
        guard settings.enginePreference != .custom else { return order }
        // Engine bị chậm hoặc hay lỗi tự xuống cuối; engine đang ngưng thì bị bỏ qua ở unavailableReason.
        return order.enumerated()
            .sorted { a, b in
                let da = health(a.element) == .degraded ? 1 : 0, db = health(b.element) == .degraded ? 1 : 0
                return da != db ? da < db : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: Hiển thị

    struct EngineInfo { var health: Health; var text: String }

    func info(_ engine: EngineKind, now: Date) -> EngineInfo {
        if settings.disabledEngines.contains(engine) { return EngineInfo(health: .off, text: L("Đã tắt", "Off")) }
        if let reason = unavailableReason(engine, now: now) {
            return EngineInfo(health: engine.needsKey && keys(for: engine).isEmpty ? .unknown : .down, text: reason.prefix(1).uppercased() + reason.dropFirst())
        }
        let s = stats[engine] ?? Stats()
        let ok = s.recent.filter(\.ok)
        guard !s.recent.isEmpty else {
            if engine.needsKey { return EngineInfo(health: .unknown, text: L("Đã có \(keys(for: engine).count) key · chưa dịch câu nào", "Keys: \(keys(for: engine).count) · nothing translated yet")) }
            return EngineInfo(health: .unknown, text: L("Sẵn sàng · chưa dùng", "Ready · not used yet"))
        }
        let avg = Int(typicalMs(engine))
        let rate = Int(Double(ok.count) / Double(s.recent.count) * 100)
        let h = health(engine, now: now)
        let word = h == .degraded ? L("Kém", "Poor") : (h == .good ? L("Tốt", "Good") : L("Đang theo dõi", "Monitoring"))
        return EngineInfo(health: h, text: L("\(word) · \(avg) ms · thành công \(rate)% · hôm nay \(s.usedToday) câu", "\(word) · \(avg) ms · \(rate)% success · \(s.usedToday) lines today"))
    }

    func keyStatus(_ k: KeyEntry, now: Date) -> (ok: Bool, text: String) {
        let r = runtime[k.id] ?? KeyRuntime()
        if let m = r.invalidReason { return (false, L("Không hợp lệ: \(m)", "Invalid: \(m)")) }
        if let until = r.cooldownUntil, until > now {
            let why = r.cooldownReason ?? L("hết hạn mức", "out of quota")
            return (false, L("Tạm ngưng: \(why). Dùng lại sau \(Self.human(until.timeIntervalSince(now)))",
                             "Paused: \(why). Back in \(Self.human(until.timeIntervalSince(now)))"))
        }
        let used = r.day == today() ? r.usedToday : 0
        var t = L("Hoạt động · hôm nay \(used) câu", "Active · \(used) lines today")
        if let rem = r.remaining, let lim = r.limit { t += L(" · còn \(rem)/\(lim) lượt", " · \(rem)/\(lim) requests left") }
        return (true, t)
    }

    func clearLog() { log = [] }

    private func note(_ text: String, resumeAt: Date? = nil) {
        // Không ghi lặp cùng một dòng liên tiếp.
        if let last = log.first, last.text == text, Date().timeIntervalSince(last.time) < 30 { return }
        log.insert(LogEntry(time: Date(), text: text, resumeAt: resumeAt), at: 0)
        if log.count > 60 { log.removeLast(log.count - 60) }
    }

    static func human(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s < 60 { return L("\(s) giây", "\(s) sec") }
        if s < 3600 { return L("\(s / 60) phút \(s % 60) giây", "\(s / 60) min \(s % 60) sec") }
        return L("\(s / 3600) giờ \((s % 3600) / 60) phút", "\(s / 3600) hr \((s % 3600) / 60) min")
    }
}

/// Chạy một engine dịch, kèm một engine dự phòng chạy song song khi engine đầu chậm hoặc lỗi; kết quả nào về trước thì dùng,
/// yêu cầu còn lại bị huỷ. Không đợi engine bị huỷ chạy xong (Apple có thể không dừng ngay), nên không dùng task group.
@MainActor
final class Hedge {
    typealias Result = (outcome: TranslationOutcome?, failures: [(EngineKind, String)], backupWon: Bool)
    private let run: (EngineKind, @escaping @MainActor (String) -> Void) async throws -> TranslationOutcome
    private let onPartial: (@MainActor (String) -> Void)?
    private var owner: EngineKind?          // engine đầu tiên ra chữ theo luồng: chỉ hiện chữ của engine này
    private var primary: EngineKind?
    private var backupTimer: Task<Void, Never>?
    private var cont: CheckedContinuation<Result, Never>?
    private var pending = 0
    private var failures: [(EngineKind, String)] = []
    private var tasks: [Task<Void, Never>] = []
    private var backupStarted = false

    init(run: @escaping (EngineKind, @escaping @MainActor (String) -> Void) async throws -> TranslationOutcome,
         onPartial: (@MainActor (String) -> Void)? = nil) {
        self.run = run
        self.onPartial = onPartial
    }

    /// Engine đầu đã bắt đầu ra chữ thì nó còn sống: không cần gửi thêm cho engine dự phòng.
    private func partial(from e: EngineKind, _ text: String) {
        guard cont != nil else { return }
        if owner == nil {
            owner = e
            if e == primary { backupTimer?.cancel() }
        }
        guard owner == e else { return }
        onPartial?(text)
    }

    func start(_ a: EngineKind, backup b: EngineKind?, after delay: Double) async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            cont = c
            primary = a
            launch(a, isBackup: false, backup: b)
            if let b {
                let timer = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.startBackup(b)
                }
                backupTimer = timer
                tasks.append(timer)
            }
        }
    }

    private func launch(_ e: EngineKind, isBackup: Bool, backup: EngineKind?) {
        pending += 1
        tasks.append(Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let o = try await self.run(e) { [weak self] text in self?.partial(from: e, text) }
                self.finish(o, backupWon: isBackup)
            } catch is CancellationError {
                self.settle()
            } catch {
                self.failures.append((e, (error as? Failure)?.message ?? error.localizedDescription))
                if !isBackup, let backup { self.startBackup(backup) }   // engine đầu lỗi sớm: chạy luôn engine dự phòng
                self.settle()
            }
        })
    }

    private func startBackup(_ b: EngineKind) {
        guard !backupStarted, cont != nil else { return }
        backupStarted = true
        launch(b, isBackup: true, backup: nil)
    }

    private func finish(_ o: TranslationOutcome, backupWon: Bool) {
        guard let c = cont else { return }
        cont = nil
        tasks.forEach { $0.cancel() }
        c.resume(returning: (o, failures, backupWon))
    }

    private func settle() {
        pending -= 1
        guard pending <= 0, let c = cont else { return }
        cont = nil
        tasks.forEach { $0.cancel() }
        c.resume(returning: (nil, failures, false))
    }
}
