import Foundation

/// Bộ nhớ dịch theo hồ sơ game: câu đã dịch được lưu lại, gặp lại (NPC nói lặp, xem lại hội thoại, bảng nhiệm vụ) thì dùng ngay,
/// không gọi API, không tốn lượt. Lưu theo hồ sơ và theo ngôn ngữ dịch, tối đa 4.000 câu (bỏ câu lâu không dùng nhất).
@MainActor
final class TranslationMemory {
    struct Entry: Codable { var text: String; var used: Date }

    static let limit = 4000
    private let settings: AppSettings
    private var profile: UUID?
    private var entries: [String: Entry] = [:]
    private var saveTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        load(profile: settings.activePresetID)
    }

    private static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["OVERSUB_MEMORY_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return AppPaths.support.appendingPathComponent("memory", isDirectory: true)
    }
    private static func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    var count: Int { entries.count }

    /// Số câu đã nhớ của một hồ sơ (để hiện ở trang chi tiết), đọc từ tệp nếu không phải hồ sơ đang dùng.
    func count(for id: UUID) -> Int {
        if id == profile { return entries.count }
        guard let data = try? Data(contentsOf: Self.url(id)),
              let e = try? JSONDecoder().decode([String: Entry].self, from: data) else { return 0 }
        return e.count
    }

    func load(profile id: UUID?) {
        flush()
        profile = id
        entries = [:]
        guard let id, let data = try? Data(contentsOf: Self.url(id)),
              let e = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        // Câu nhiều từ mà "bản dịch" y nguyên câu gốc thường là AI giữ nguyên nhầm cả dòng (vd. "Scan amiibo" chỉ vì có tên
        // riêng): bỏ để lần sau dịch lại. Từ đơn như "Menu" vẫn giữ, khỏi hỏi lại mỗi lần.
        entries = e.filter { k, v in
            let src = String(k.split(separator: "|", maxSplits: 1).last ?? "")
            return !(TextUtil.normalize(v.text) == src && v.text.split(separator: " ").count >= 2)
        }
    }

    private func key(_ source: String) -> String { settings.targetLanguage + "|" + TextUtil.normalize(source) }

    func lookup(_ source: String) -> String? {
        let k = key(source)
        guard k.count > settings.targetLanguage.count + 4, var e = entries[k] else { return nil }
        e.used = Date()
        entries[k] = e
        scheduleSave()
        return e.text
    }

    func store(_ source: String, _ translation: String) {
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key(source)
        guard !t.isEmpty, k.count > settings.targetLanguage.count + 4 else { return }
        entries[k] = Entry(text: t, used: Date())
        if entries.count > Self.limit {
            let drop = entries.sorted { $0.value.used < $1.value.used }.prefix(entries.count - Self.limit)
            drop.forEach { entries[$0.key] = nil }
        }
        scheduleSave()
    }

    /// Xoá bộ nhớ dịch của một hồ sơ (vd. sau khi thêm thuật ngữ, muốn dịch lại cho đúng tên riêng).
    func clear(_ id: UUID) {
        if id == profile { entries = [:] }
        try? FileManager.default.removeItem(at: Self.url(id))
    }

    /// Nhân bản hồ sơ: mang theo bộ nhớ dịch.
    func copy(from: UUID, to: UUID) {
        flush()
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: Self.url(to))
        try? FileManager.default.copyItem(at: Self.url(from), to: Self.url(to))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard let id = profile, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: Self.url(id), options: .atomic)
    }
}
