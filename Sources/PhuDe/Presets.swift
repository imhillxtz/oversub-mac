import Foundation
import AppKit

/// Ảnh chụp toàn bộ cài đặt cho một game, kể cả vùng chọn, từ điển thuật ngữ và danh sách luôn bỏ qua.
/// Không gồm key API, số liệu engine, tên model: những thứ đó dùng chung cho mọi game.
/// Mọi trường đều tuỳ chọn, để preset lưu ở bản cũ vẫn đọc được khi app có thêm cài đặt mới.
struct PresetSnapshot: Codable, Equatable {
    var mode: String?, style: String?, fontSize: Double?, speakEnabled: Bool?, speechRate: Double?, speechVolume: Double?
    var sourceLanguage: String?, captureMode: String?, enginePreference: String?, customOrder: [String]?, disabledEngines: [String]?
    var showOriginal: Bool?, showTranslation: Bool?, showScanRegion: Bool?, windowFontSize: Double?
    var overlayEnabled: Bool?, overlayFit: Bool?, overlayFollow: Bool?, overlayAlign: String?, overlayFontScale: Double?
    var overlayDX: Double?, overlayDY: Double?, overlayWidthPct: Double?, autoSpeechRate: Bool?
    var genre: String?, smartSubtitleOnly: Bool?, smartPronouns: Bool?, smartNames: Bool?, contextResetSeconds: Double?
    var ignoreList: [String]?, glossary: [GlossaryEntry]?
    var region: CaptureRegion?, gameAppName: String?, gameBundleID: String?, pauseWhenGameHidden: Bool?
    var targetLanguage: String?
    var outputMode: String?, voiceSource: String?, cast: [CastMember]?, contextAutoForget: Bool?
    var duckEnabled: Bool?, duckLevel: Double?, dubEmotion: Bool?, dropStaleLines: Bool?, dubCharacters: Bool?
    var secondaryRegion: CaptureRegion?        // bản trước: một vùng phụ
    var secondaryRegions: [CaptureRegion]?
    var customStyle: CustomStyle?
}

struct Preset: Codable, Identifiable, Equatable {
    /// Preset Mặc định: luôn có, không xoá được, có nút khôi phục cài đặt ban đầu.
    static let defaultID = UUID(uuidString: "0F5E5B00-0000-4000-8000-00000000DEF0")!

    var id = UUID()
    var name: String
    var updatedAt = Date()
    var snapshot: PresetSnapshot
    var lastUsedAt: Date?       // lần dùng gần nhất: nhiều hồ sơ cùng một game thì tự chuyển sang hồ sơ dùng gần nhất
    var isDefault: Bool { id == Self.defaultID }
}

/// Ngữ cảnh hội thoại (các câu gần nhất) của từng preset, lưu riêng trong một tệp để không phải ghi lại cả danh sách preset mỗi câu.
/// Dùng preset nào thì nối tiếp ngữ cảnh của preset đó.
@MainActor
enum ContextStore {
    static let limit = 30   // nhớ tối đa 30 câu gần nhất; mỗi lần dịch gửi kèm 10 câu mới nhất

    struct Entry: Codable { var target: String; var lines: [ContextLine]; var updatedAt = Date() }

    private static var url: URL {
        // Bài test dùng tệp riêng để không đụng ngữ cảnh thật của người dùng.
        if let p = ProcessInfo.processInfo.environment["OVERSUB_CONTEXT_FILE"] { return URL(fileURLWithPath: p) }
        return AppPaths.support.appendingPathComponent("contexts.json")
    }
    private static var cache: [UUID: Entry] = {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([UUID: Entry].self, from: data)) ?? [:]
    }()
    private static var saveTask: Task<Void, Never>?

    /// Ngữ cảnh của preset, chỉ khi cùng ngôn ngữ dịch (bản dịch cũ bằng ngôn ngữ khác không dùng làm ngữ cảnh được).
    static func lines(for id: UUID, target: String) -> [ContextLine] {
        guard let e = cache[id], e.target == target else { return [] }
        return e.lines
    }
    static func count(for id: UUID) -> Int { cache[id]?.lines.count ?? 0 }
    static func entry(for id: UUID) -> Entry? { cache[id] }

    static func set(_ lines: [ContextLine], for id: UUID, target: String) {
        cache[id] = Entry(target: target, lines: Array(lines.suffix(limit)))
        scheduleSave()
    }
    static func copy(from: UUID, to: UUID) {
        if let e = cache[from] { cache[to] = e; scheduleSave() }
    }
    static func remove(_ id: UUID) { cache[id] = nil; scheduleSave() }

    /// Gộp nhiều lần ghi liên tiếp thành một (hội thoại dồn dập).
    private static func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension AppSettings {
    func snapshot() -> PresetSnapshot {
        PresetSnapshot(
            mode: mode.rawValue, style: style.rawValue, fontSize: fontSize, speakEnabled: speakEnabled, speechRate: speechRate,
            speechVolume: speechVolume, sourceLanguage: sourceLanguage, captureMode: captureMode.rawValue,
            enginePreference: enginePreference.rawValue, customOrder: customOrder.map(\.rawValue),
            disabledEngines: disabledEngines.map(\.rawValue).sorted(),
            showOriginal: nil, showTranslation: nil, showScanRegion: nil, windowFontSize: windowFontSize,
            overlayEnabled: overlayEnabled, overlayFit: overlayFit, overlayFollow: overlayFollow, overlayAlign: overlayAlign.rawValue,
            overlayFontScale: overlayFontScale, overlayDX: overlayDX, overlayDY: overlayDY, overlayWidthPct: overlayWidthPct,
            autoSpeechRate: autoSpeechRate, genre: genre.rawValue, smartSubtitleOnly: smartSubtitleOnly, smartPronouns: smartPronouns,
            smartNames: smartNames, contextResetSeconds: contextResetSeconds, ignoreList: ignoreList, glossary: glossary,
            region: region, gameAppName: gameAppName, gameBundleID: gameBundleID, pauseWhenGameHidden: pauseWhenGameHidden,
            targetLanguage: targetLanguage, outputMode: outputMode.rawValue, voiceSource: voiceSource.rawValue, cast: cast,
            contextAutoForget: contextAutoForget, duckEnabled: duckEnabled, duckLevel: duckLevel, dubEmotion: dubEmotion,
            dropStaleLines: dropStaleLines, dubCharacters: dubCharacters, secondaryRegion: nil, secondaryRegions: secondaryRegions,
            customStyle: customStyle)
    }

    /// Cài đặt ban đầu của OverSub (giống lúc mới cài), dùng cho nút Khôi phục ở preset Mặc định.
    static var factorySnapshot: PresetSnapshot {
        PresetSnapshot(
            mode: DisplayMode.viOnly.rawValue, style: OverlayStyle.matchOriginal.rawValue, fontSize: 28, speakEnabled: true,
            speechRate: 0.5, speechVolume: 1, sourceLanguage: "en-US", captureMode: CaptureMode.balanced.rawValue,
            enginePreference: EnginePreference.balanced.rawValue, customOrder: EnginePreference.balanced.order!.map(\.rawValue),
            disabledEngines: [], showOriginal: nil, showTranslation: nil, showScanRegion: nil, windowFontSize: 28,
            overlayEnabled: true, overlayFit: true, overlayFollow: false, overlayAlign: OverlayAlign.auto.rawValue,
            overlayFontScale: 100, overlayDX: 0, overlayDY: 0, overlayWidthPct: 100, autoSpeechRate: true,
            genre: GameGenre.auto.rawValue, smartSubtitleOnly: true, smartPronouns: true, smartNames: true, contextResetSeconds: 45,
            ignoreList: [], glossary: [], region: nil, gameAppName: nil, gameBundleID: nil, pauseWhenGameHidden: true,
            targetLanguage: "vi", outputMode: OutputMode.both.rawValue, voiceSource: VoiceSource.apple.rawValue, cast: [],
            contextAutoForget: false, duckEnabled: false, duckLevel: 0.3, dubEmotion: true, dropStaleLines: true, dubCharacters: false,
            secondaryRegion: nil, secondaryRegions: nil, customStyle: CustomStyle())
    }

    /// Khôi phục cài đặt từ preset; trường nào preset không có (lưu ở bản cũ) thì giữ nguyên.
    func apply(_ s: PresetSnapshot) {
        if let v = s.mode.flatMap(DisplayMode.init(rawValue:)) { mode = v }
        if let v = s.style.flatMap(OverlayStyle.init(rawValue:)) { style = v }
        if let v = s.fontSize { fontSize = v }
        if let v = s.speakEnabled { speakEnabled = v }
        if let v = s.speechRate { speechRate = v }
        if let v = s.speechVolume { speechVolume = v }
        if let v = s.sourceLanguage { sourceLanguage = v }
        if let v = CaptureMode.from(s.captureMode) { captureMode = v }
        if let v = s.targetLanguage { targetLanguage = v }
        if let v = s.enginePreference.flatMap(EnginePreference.init(rawValue:)) { enginePreference = v }
        if let v = s.customOrder?.compactMap(EngineKind.init(rawValue:)), !v.isEmpty { customOrder = EngineKind.completed(v) }
        if let v = s.disabledEngines { disabledEngines = Set(v.compactMap(EngineKind.init(rawValue:))) }
        if let v = s.windowFontSize { windowFontSize = v }
        if let v = s.overlayEnabled { overlayEnabled = v }
        if let v = s.overlayFit { overlayFit = v }
        if let v = s.overlayFollow { overlayFollow = v }
        if let v = s.overlayAlign.flatMap(OverlayAlign.init(rawValue:)) { overlayAlign = v }
        if let v = s.overlayFontScale { overlayFontScale = v }
        if let v = s.overlayDX { overlayDX = v }
        if let v = s.overlayDY { overlayDY = v }
        if let v = s.overlayWidthPct { overlayWidthPct = v }
        if let v = s.autoSpeechRate { autoSpeechRate = v }
        if let v = s.customStyle { customStyle = v }
        if let v = s.genre.flatMap(GameGenre.init(rawValue:)) { genre = v }
        if let v = s.smartSubtitleOnly { smartSubtitleOnly = v }
        if let v = s.smartPronouns { smartPronouns = v }
        if let v = s.smartNames { smartNames = v }
        if let v = s.contextResetSeconds { contextResetSeconds = v }
        if let v = s.ignoreList { ignoreList = v }
        if let v = s.glossary { glossary = v }
        if let v = s.region { region = v }
        if s.region != nil || s.gameAppName != nil { gameAppName = s.gameAppName; gameBundleID = s.gameBundleID }
        if let v = s.pauseWhenGameHidden { pauseWhenGameHidden = v }
        if let v = s.outputMode.flatMap(OutputMode.init(rawValue:)) {
            // Preset cũ lưu "Chỉ thuyết minh": thuyết minh bật, phụ đề đè lên game tắt.
            if v == .dub { outputMode = .both; overlayEnabled = false } else { outputMode = v }
        }
        if let v = s.voiceSource.flatMap(VoiceSource.init(rawValue:)) { voiceSource = v }
        if let v = s.cast { cast = v }
        if let v = s.contextAutoForget { contextAutoForget = v }
        if let v = s.duckEnabled { duckEnabled = v }
        if let v = s.duckLevel { duckLevel = v }
        if let v = s.dubEmotion { dubEmotion = v }
        if let v = s.dropStaleLines { dropStaleLines = v }
        if let v = s.dubCharacters { dubCharacters = v }
        // Vùng phụ đi theo preset: preset có lưu vùng chính mà không có vùng phụ nghĩa là preset đó không dùng vùng phụ.
        if let v = s.secondaryRegions { secondaryRegions = v }
        else if let old = s.secondaryRegion { secondaryRegions = [old] }
        else if s.region != nil { secondaryRegions = [] }   // hồ sơ có khung chính mà không có vùng phụ
    }

    /// Luôn có ít nhất một hồ sơ. Hồ sơ đầu tiên là hồ sơ bình thường (đổi tên, xoá được); người dùng bản cũ chưa có hồ sơ nào
    /// thì hồ sơ đầu giữ đúng cài đặt họ đang dùng.
    func ensureDefaultPreset() {
        if presets.isEmpty {
            presets = [Preset(id: Preset.defaultID, name: L("Mặc định", "Default"), snapshot: snapshot(), lastUsedAt: Date())]
        }
        if activePresetID == nil || !presets.contains(where: { $0.id == activePresetID }) { activePresetID = presets[0].id }
    }

    /// Tự lưu: mọi thay đổi cài đặt ghi ngay vào hồ sơ đang dùng, không cần bấm Lưu.
    func syncActiveProfile() {
        guard let i = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
        let snap = snapshot()
        guard presets[i].snapshot != snap else { return }
        presets[i].snapshot = snap
        presets[i].updatedAt = Date()
    }

    /// Hồ sơ mới cho game khác: dùng cài đặt hiện tại, trí nhớ game (dàn diễn viên, thuật ngữ, danh sách bỏ qua) bắt đầu trống.
    @discardableResult
    func createProfile(named raw: String) -> Preset {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var snap = snapshot()
        snap.cast = []; snap.glossary = []; snap.ignoreList = []
        let p = Preset(name: name.isEmpty ? L("Hồ sơ \(presets.count + 1)", "Profile \(presets.count + 1)") : name, snapshot: snap, lastUsedAt: Date())
        presets.append(p)
        activePresetID = p.id
        apply(snap)
        return p
    }

    /// Hồ sơ cài đặt ban đầu (khi xoá hồ sơ cuối cùng).
    func makeFactoryProfile() -> Preset {
        var snap = Self.factorySnapshot
        snap.region = region; snap.gameAppName = gameAppName; snap.gameBundleID = gameBundleID
        let p = Preset(name: L("Mặc định", "Default"), snapshot: snap, lastUsedAt: Date())
        presets.append(p)
        return p
    }

    /// Đưa cài đặt của một hồ sơ về như lúc mới cài; giữ khung phụ đề, vùng phụ, game đã nhận diện và trí nhớ game.
    func resetProfileSettings(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        let old = presets[i].snapshot
        var snap = Self.factorySnapshot
        snap.region = old.region; snap.secondaryRegions = old.secondaryRegions ?? old.secondaryRegion.map { [$0] }
        snap.gameAppName = old.gameAppName; snap.gameBundleID = old.gameBundleID
        snap.cast = old.cast; snap.glossary = old.glossary; snap.ignoreList = old.ignoreList
        presets[i].snapshot = snap
        presets[i].updatedAt = Date()
        if id == activePresetID { apply(snap) }
    }

    /// Xoá trí nhớ game của hồ sơ trong cài đặt (dàn diễn viên, thuật ngữ, danh sách bỏ qua). Ngữ cảnh và bộ nhớ dịch do Engine xoá.
    func clearProfileMemory(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].snapshot.cast = []; presets[i].snapshot.glossary = []; presets[i].snapshot.ignoreList = []
        if id == activePresetID { cast = []; glossary = []; ignoreList = [] }
        ContextStore.remove(id)
    }

    /// Khôi phục preset Mặc định về cài đặt ban đầu. Giữ khung phụ đề và game đã nhận diện để khỏi phải chọn lại.
    func resetDefaultPreset() {
        guard let i = presets.firstIndex(where: { $0.isDefault }) else { return }
        var snap = Self.factorySnapshot
        snap.region = presets[i].snapshot.region ?? region
        snap.gameAppName = presets[i].snapshot.gameAppName ?? gameAppName
        snap.gameBundleID = presets[i].snapshot.gameBundleID ?? gameBundleID
        presets[i].snapshot = snap
        presets[i].updatedAt = Date()
        ContextStore.remove(Preset.defaultID)
    }

    /// Dàn diễn viên tự lưu vào preset đang dùng (nhân vật mới, giọng đã chỉnh), không cần bấm Lưu đè.
    func syncCastToActivePreset() {
        guard let i = presets.firstIndex(where: { $0.id == activePresetID }), presets[i].snapshot.cast != cast else { return }
        presets[i].snapshot.cast = cast
    }

    /// Sửa nhanh một preset (trang chi tiết). Preset đang dùng thì áp dụng luôn.
    func updatePreset(_ id: UUID, _ change: (inout PresetSnapshot) -> Void) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        change(&presets[i].snapshot)
        presets[i].updatedAt = Date()
        // Chỉ áp dụng đúng trường vừa đổi, không đè các chỉnh sửa chưa lưu khác của preset đang dùng.
        if id == activePresetID {
            var partial = PresetSnapshot()
            change(&partial)
            apply(partial)
        }
    }

    var activePreset: Preset? { presets.first { $0.id == activePresetID } }

    /// Đã chỉnh gì đó sau khi áp dụng preset đang dùng chưa.
    var activePresetModified: Bool {
        guard let p = activePreset else { return false }
        // Chỉ so các trường preset có lưu: preset tạo ở bản cũ thiếu cài đặt mới (vd. ngôn ngữ dịch) không bị coi là đã chỉnh.
        let enc = JSONEncoder()
        guard let a = try? enc.encode(p.snapshot), let b = try? enc.encode(snapshot()),
              let saved = try? JSONSerialization.jsonObject(with: a) as? [String: Any],
              let now = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return p.snapshot != snapshot() }
        // Cài đặt đã bỏ ở OverSub, và dàn diễn viên (tự lưu vào preset đang dùng nên không tính là "đã chỉnh").
        let retired: Set<String> = ["showOriginal", "showTranslation", "showScanRegion", "cast"]
        return saved.contains { key, value in
            if retired.contains(key) { return false }
            guard let cur = now[key] else { return true }
            return !(value as AnyObject).isEqual(cur)
        }
    }

    @discardableResult
    func savePreset(named raw: String) -> Preset {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Preset(name: name.isEmpty ? L("Hồ sơ \(presets.count + 1)", "Profile \(presets.count + 1)") : name, snapshot: snapshot())
        presets.append(p)
        // Preset mới mang theo ngữ cảnh hội thoại đang có, rồi nối tiếp từ đó.
        if let old = activePresetID { ContextStore.copy(from: old, to: p.id) }
        activePresetID = p.id
        return p
    }

    func overwriteActivePreset() {
        guard let i = presets.firstIndex(where: { $0.id == activePresetID }) else { return }
        presets[i].snapshot = snapshot()
        presets[i].updatedAt = Date()
    }

    func overwritePreset(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].snapshot = snapshot()
        presets[i].updatedAt = Date()
        activePresetID = id
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        presets[i].name = name
    }

    func duplicatePreset(_ id: UUID) {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        let copy = Preset(name: p.name + L(" (bản sao)", " (copy)"), snapshot: p.snapshot)
        presets.append(copy)
        ContextStore.copy(from: id, to: copy.id)
    }

    /// Xoá hồ sơ. Trả về hồ sơ cần chuyển sang nếu vừa xoá hồ sơ đang dùng. Xoá hồ sơ cuối cùng thì tạo lại một hồ sơ cài đặt ban đầu.
    @discardableResult
    func deletePreset(_ id: UUID) -> Preset? {
        presets.removeAll { $0.id == id }
        ContextStore.remove(id)
        if presets.isEmpty { return makeFactoryProfile() }
        if activePresetID == id { return presets.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) } }
        return nil
    }

    /// Tên gợi ý khi lưu preset mới: theo game đã nhận diện và thể loại.
    var suggestedPresetName: String {
        let genreShort = genre == .auto ? "" : " – " + (genre.title.components(separatedBy: " (").first ?? "")
        return (gameAppName ?? "Game") + genreShort
    }
}

/// Tệp chia sẻ preset: {"app":"OverSub","version":1,"presets":[...]}.
struct PresetFile: Codable {
    var app = "OverSub"
    var version = 1
    var presets: [Preset]
}

extension AppSettings {
    func exportPresets(_ ids: Set<UUID>? = nil) throws -> Data {
        let list = ids.map { set in presets.filter { set.contains($0.id) } } ?? presets
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(PresetFile(presets: list))
    }

    /// Nhập preset từ tệp; mỗi preset nhận id mới để không đè lên preset sẵn có, trùng tên thì thêm "(2)".
    @discardableResult
    func importPresets(_ data: Data) throws -> Int {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(PresetFile.self, from: data)
        for var p in file.presets {
            p.id = UUID()
            var name = p.name, n = 2
            while presets.contains(where: { $0.name == name }) { name = "\(p.name) (\(n))"; n += 1 }
            p.name = name
            presets.append(p)
        }
        return file.presets.count
    }
}


/// Ảnh màn hình (đã dừng hình) lúc lưu vùng chọn, để xem lại các vùng trong trang hồ sơ.
@MainActor
enum RegionThumbs {
    private static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["OVERSUB_THUMB_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return AppPaths.support.appendingPathComponent("thumbs", isDirectory: true)
    }
    private static func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).jpg") }
    private static var cache: [UUID: NSImage] = [:]

    /// Thu nhỏ còn khoảng 900 điểm ảnh bề ngang rồi lưu JPEG.
    static func save(_ image: CGImage, for id: UUID) {
        let w = min(900, image.width), h = Int(Double(image.height) * Double(w) / Double(image.width))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url(id), options: .atomic)
        cache[id] = NSImage(cgImage: small, size: NSSize(width: w, height: h))
    }

    static func image(for id: UUID) -> NSImage? {
        if let c = cache[id] { return c }
        let img = NSImage(contentsOf: url(id))
        cache[id] = img
        return img
    }

    static func copy(from: UUID, to: UUID) {
        try? FileManager.default.removeItem(at: url(to))
        try? FileManager.default.copyItem(at: url(from), to: url(to))
        cache[to] = nil
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        cache[id] = nil
    }
}
