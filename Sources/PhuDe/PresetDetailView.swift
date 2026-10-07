import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Xuất, nhập preset qua tệp JSON.
@MainActor
enum PresetIO {
    static func export(_ settings: AppSettings, ids: Set<UUID>? = nil) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let single = ids?.count == 1 ? settings.presets.first { ids!.contains($0.id) } : nil
        panel.nameFieldStringValue = (single?.name ?? L("OverSub - hồ sơ game", "OverSub - game profiles")) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try settings.exportPresets(ids).write(to: url)
            return L("Đã xuất ra \(url.lastPathComponent).", "Exported to \(url.lastPathComponent).")
        } catch {
            return L("Không xuất được: \(error.localizedDescription)", "Couldn't export: \(error.localizedDescription)")
        }
    }

    static func importFile(_ settings: AppSettings) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let n = try settings.importPresets(Data(contentsOf: url))
            return n == 0 ? L("Tệp không có hồ sơ nào.", "The file contains no profiles.") : L("Đã nhập \(n) hồ sơ.", "Imported \(n) profiles.")
        } catch {
            return L("Tệp này không phải hồ sơ game của OverSub.", "This file isn't an OverSub game profile.")
        }
    }
}

@MainActor
final class PresetDetailState: ObservableObject {
    @Published var confirmReset = false
    @Published var confirmDelete = false
    @Published var confirmClearMemory = false
    @Published var message = ""
    @Published var tick = 0      // vẽ lại sau khi xoá ngữ cảnh (ContextStore không tự báo thay đổi)
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// Trang chi tiết một preset: tóm tắt, cài đặt nhanh, ngữ cảnh đã nhớ, và các thao tác.
struct PresetDetailView: View {
    let id: UUID
    var onBack: () -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @StateObject private var state = PresetDetailState()

    private static var dateFormat: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: L("vi_VN", "en_US")); f.dateFormat = L("dd/MM/yyyy 'lúc' HH:mm", "MMM d, yyyy 'at' HH:mm"); return f
    }

    private var preset: Preset? { settings.presets.first { $0.id == id } }

    var body: some View {
        if let p = preset {
            content(p)
        } else {
            VStack(spacing: 10) {
                Text(L("Hồ sơ này đã bị xoá.", "This profile has been deleted.")).foregroundStyle(.secondary)
                Button(L("Về danh sách hồ sơ", "Back to profiles"), action: onBack)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ p: Preset) -> some View {
        _ = state.tick
        let s = p.snapshot
        let f = AppSettings.factorySnapshot
        let active = p.id == settings.activePresetID
        let speaks = OutputMode(rawValue: s.outputMode ?? "")?.speaks ?? (s.speakEnabled ?? true)
        let isLast = settings.presets.count == 1
        let styleTitle = OverlayStyle(rawValue: s.style ?? "")?.title ?? L("Khớp màu phụ đề gốc", "Match original subtitle color")
        return Form {
            Section {
                Button(action: onBack) {
                    Label(L("Tất cả hồ sơ", "All profiles"), systemImage: "chevron.left").font(.callout.weight(.medium))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 34)).foregroundStyle(Color.indigo.gradient)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L("Tên", "Name"), text: Binding(get: { preset?.name ?? "" }, set: { settings.renamePreset(id, to: $0) }))
                            .textFieldStyle(.plain).font(.title2.weight(.semibold)).labelsHidden()
                        HStack(spacing: 6) {
                            if active { badge(L("Đang dùng · tự lưu", "In use · autosaved"), .green) }
                            Text(L("Cập nhật \(Self.dateFormat.string(from: p.updatedAt))", "Updated \(Self.dateFormat.string(from: p.updatedAt))")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !active {
                        Button(L("Dùng hồ sơ này", "Use this profile")) { engine.applyPreset(p) }.buttonStyle(.glassProminent).tint(Theme.accent)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Game", value: s.gameAppName ?? L("Chưa nhận diện", "Not detected"))
                LabeledContent(L("Vùng phụ đề", "Subtitle region"), value: s.region.map { L("\(Int($0.w)) × \(Int($0.h)) tại (\(Int($0.x)), \(Int($0.y)))", "\(Int($0.w)) × \(Int($0.h)) at (\(Int($0.x)), \(Int($0.y)))") } ?? L("Chưa chọn", "Not set"))
                LabeledContent(L("Dịch màn hình", "Screen translation"), value: { let n = (s.secondaryRegions ?? s.secondaryRegion.map { [$0] } ?? []).count; return n == 0 ? L("Không có vùng", "No regions") : L("\(n) vùng", "\(n) regions") }())
                LabeledContent(L("Dịch", "Translation"), value: "\(SourceLanguage.find(s.sourceLanguage ?? f.sourceLanguage!).displayName) → \(TargetLanguage.find(s.targetLanguage ?? f.targetLanguage!).displayName)")
                LabeledContent(L("Phụ đề đè lên game", "Subtitles over the game"), value: (s.overlayEnabled ?? true)
                               ? L("\(styleTitle), cỡ \(Int(s.overlayFontScale ?? 100))%", "\(styleTitle), size \(Int(s.overlayFontScale ?? 100))%") : L("Tắt", "Off"))
                LabeledContent(L("Giọng đọc", "Voice"), value: speaks
                               ? ((s.dubCharacters ?? false) ? L("Dub, giọng theo nhân vật", "Dub, per-character voices") : L("Voice-over, một giọng Siri", "Voice-over, one Siri voice")) + ((s.duckEnabled ?? false) ? L(", giảm tiếng game", ", game audio lowered") : "") : L("Tắt", "Off"))
                LabeledContent(L("Dịch vụ dịch", "Translation services"), value: EnginePreference(rawValue: s.enginePreference ?? "")?.title ?? L("Cân bằng", "Balanced"))
                LabeledContent(L("Chất lượng dịch", "Translation quality"), value: [
                    (s.smartSubtitleOnly ?? true) ? L("lọc phụ đề", "subtitle filter") : nil, (s.smartPronouns ?? true) ? L("giữ xưng hô", "consistent forms of address") : nil,
                    (s.smartNames ?? true) ? L("giữ tên riêng", "names kept") : nil,
                ].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? L("tắt", "off"))
            } header: { Text(L("Tóm tắt", "Summary")) }

            Section {
                RegionMap(main: s.region, secondaries: s.secondaryRegions ?? s.secondaryRegion.map { [$0] } ?? [],
                          thumbnail: RegionThumbs.image(for: p.id))
                    .padding(.vertical, 4)
                HStack {
                    Note(RegionThumbs.image(for: p.id) == nil
                         ? L("Chưa có ảnh xem trước. Bạn bấm Chỉnh vùng rồi lưu lại để có ảnh màn hình kèm các vùng.", "No preview yet. Click Edit regions and save to capture a screenshot with the regions.")
                         : L("Ảnh màn hình lúc lưu vùng. Viền trắng là vùng phụ đề, viền cam là vùng dịch màn hình.", "Screenshot from when the regions were saved. The white outline is the subtitle region; orange outlines are screen regions."))
                    Spacer()
                    Button(L("Chỉnh vùng…", "Edit regions…")) { engine.editRegions(forProfile: id) }
                }
            } header: { Text(L("Vùng chọn", "Regions")) }

            Section {
                Toggle(L("Phụ đề đè lên game", "Subtitles over the game"), isOn: bind({ ($0.overlayEnabled ?? true) && $0.outputMode != OutputMode.dub.rawValue },
                                                        { $0.overlayEnabled = $1; if $0.outputMode == OutputMode.dub.rawValue { $0.outputMode = OutputMode.both.rawValue } }))
                Toggle(L("Giọng đọc", "Voice"), isOn: bind({ OutputMode(rawValue: $0.outputMode ?? "")?.speaks ?? ($0.speakEnabled ?? true) },
                                                { $0.outputMode = ($1 ? OutputMode.both : .subtitles).rawValue; $0.speakEnabled = $1 }))
                Picker(L("Kiểu giọng", "Voice style"), selection: bind({ $0.dubCharacters ?? false }, { $0.dubCharacters = $1 })) {
                    Text(L("Voice-over · một giọng", "Voice-over · one voice")).tag(false)
                    Text(L("Dub · theo nhân vật (beta)", "Dub · per character (beta)")).tag(true)
                }
                .pickerStyle(.segmented)
                Picker(L("Dịch sang", "Translate to"), selection: bind({ $0.targetLanguage ?? "vi" }, { $0.targetLanguage = $1 })) {
                    ForEach(TargetLanguage.all) { Text($0.displayName).tag($0.code) }
                }
                Picker(L("Thể loại", "Genre"), selection: bind({ GameGenre(rawValue: $0.genre ?? "") ?? .auto }, { $0.genre = $1.rawValue })) {
                    ForEach(GameGenre.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Bắt thoại", "Dialogue capture"), selection: bind({ CaptureMode.from($0.captureMode) ?? .balanced }, { $0.captureMode = $1.rawValue })) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Note(active ? L("Đổi ở đây áp dụng ngay vì đây là hồ sơ đang dùng.", "Changes here apply right away because this profile is in use.") : L("Đổi ở đây chỉ sửa hồ sơ này; bấm Dùng hồ sơ này để chuyển sang.", "Changes here only edit this profile; click Use this profile to switch to it."))
            } header: { Text(L("Cài đặt nhanh", "Quick settings")) }

            Section {
                LabeledContent(L("Ngữ cảnh hội thoại", "Dialogue context"), value: L("\(active ? engine.contextCount : ContextStore.count(for: p.id))/\(ContextStore.limit) câu", "\(active ? engine.contextCount : ContextStore.count(for: p.id))/\(ContextStore.limit) lines"))
                LabeledContent(L("Bộ nhớ dịch", "Translation memory"), value: L("\(engine.memory.count(for: p.id)) câu", "\(engine.memory.count(for: p.id)) lines"))
                LabeledContent(L("Dàn diễn viên", "Cast"), value: L("\((s.cast ?? []).filter { !$0.isNarrator }.count) nhân vật", "\((s.cast ?? []).filter { !$0.isNarrator }.count) characters"))
                LabeledContent(L("Thuật ngữ / luôn bỏ qua", "Glossary terms / always ignored"), value: "\(s.glossary?.count ?? 0) / \(s.ignoreList?.count ?? 0)")
                contextPreview(p)
            } header: { Text(L("Trí nhớ game", "Game memory")) } footer: {
                Text(L("Trí nhớ lưu cách xưng hô, giọng nhân vật, tên riêng và các câu đã dịch; câu gặp lại được đọc ngay. Tự lưu theo hồ sơ.", "Memory stores forms of address, character voices, names and lines already translated; a line seen before is read right away. Saved automatically per profile."))
            }

            Section {
                Button(L("Nhân bản (giữ cả trí nhớ)", "Duplicate (with memory)")) { engine.duplicateProfile(id); state.message = L("Đã tạo bản sao.", "Copy created.") }
                Button(L("Xuất ra tệp…", "Export to file…")) { if let m = PresetIO.export(settings, ids: [id]) { state.message = m } }
                Button(L("Khôi phục cài đặt ban đầu…", "Restore default settings…")) { state.confirmReset = true }
                Button(L("Xoá trí nhớ game…", "Clear game memory…"), role: .destructive) { state.confirmClearMemory = true }
                Button(L("Xoá hồ sơ…", "Delete profile…"), role: .destructive) { state.confirmDelete = true }
            } header: { Text(L("Thao tác", "Actions")) } footer: {
                if !state.message.isEmpty { Text(state.message) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("Khôi phục cài đặt ban đầu cho \"\(p.name)\"?", "Restore default settings for \"\(p.name)\"?"), isPresented: $state.confirmReset) {
            Button(L("Khôi phục", "Restore")) {
                settings.resetProfileSettings(id)
                state.message = L("Đã khôi phục cài đặt ban đầu.", "Default settings restored.")
                state.tick += 1
            }
        } message: {
            Text(L("Dịch, phụ đề, giọng đọc, bắt thoại và dịch vụ dịch trở về như lúc mới cài OverSub. Vùng phụ đề, vùng dịch màn hình, game đã nhận diện và trí nhớ game được giữ.", "Translation, subtitles, voice, dialogue capture and translation services go back to how they were when OverSub was first installed. The subtitle region, screen regions, detected game and game memory are kept."))
        }
        .confirmationDialog(L("Xoá trí nhớ game của \"\(p.name)\"?", "Clear game memory for \"\(p.name)\"?"), isPresented: $state.confirmClearMemory) {
            Button(L("Xoá trí nhớ", "Clear memory"), role: .destructive) {
                engine.clearProfileMemory(id)
                state.message = L("Đã xoá trí nhớ game.", "Game memory cleared.")
                state.tick += 1
            }
        } message: {
            Text(L("Xoá ngữ cảnh hội thoại, dàn diễn viên, thuật ngữ, danh sách luôn bỏ qua và bộ nhớ dịch của hồ sơ này. Cài đặt giữ nguyên.", "Clears this profile's dialogue context, cast, glossary, always-ignore list and translation memory. Settings are kept."))
        }
        .confirmationDialog(L("Xoá hồ sơ \"\(p.name)\"?", "Delete profile \"\(p.name)\"?"), isPresented: $state.confirmDelete) {
            Button(L("Xoá", "Delete"), role: .destructive) { engine.deleteProfile(id); onBack() }
        } message: {
            Text(isLast
                 ? L("Đây là hồ sơ cuối cùng. Nếu xoá, OverSub sẽ tạo lại một hồ sơ \"Mặc định\" với cài đặt ban đầu (giữ vùng phụ đề).", "This is the last profile. If you delete it, OverSub creates a new \"Default\" profile with default settings (keeping the subtitle region).")
                 : L("Trí nhớ game của hồ sơ này cũng bị xoá theo. Việc này không hoàn tác được.", "This also deletes the profile's game memory. This can't be undone."))
        }
    }

    @ViewBuilder
    private func contextPreview(_ p: Preset) -> some View {
        let active = p.id == settings.activePresetID
        let entry = ContextStore.entry(for: p.id)
        let lines = entry?.lines ?? []
        if !lines.isEmpty {
            DisclosureGroup(L("Xem 6 câu gần nhất", "Show the 6 latest lines")) {
                ForEach(Array(lines.suffix(6).enumerated()), id: \.offset) { _, l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((l.speaker.map { "\($0): " } ?? "") + l.vi).font(.callout).lineLimit(2)
                        Text(l.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let e = entry, e.target != settings.targetLanguage, active {
                    Note(L("Ngữ cảnh này được dịch sang \(TargetLanguage.find(e.target).displayName), khác ngôn ngữ đang dùng nên tạm không gửi kèm.",
                           "This context was translated into \(TargetLanguage.find(e.target).displayName), which differs from the current language, so it isn't being sent for now."))
                }
                Button(L("Chỉ xoá ngữ cảnh hội thoại", "Clear dialogue context only")) {
                    if active { engine.clearContext() } else { ContextStore.remove(p.id) }
                    state.tick += 1
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
    }

    private func bind<T>(_ get: @escaping (PresetSnapshot) -> T, _ set: @escaping (inout PresetSnapshot, T) -> Void) -> Binding<T> {
        Binding(get: { get(preset?.snapshot ?? AppSettings.factorySnapshot) },
                set: { v in settings.updatePreset(id) { set(&$0, v) } })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


/// Ảnh màn hình (lúc lưu vùng) với khung phụ đề và các vùng dịch màn hình vẽ lên, để xem lại vùng của một hồ sơ.
struct RegionMap: View {
    let main: CaptureRegion?
    let secondaries: [CaptureRegion]
    let thumbnail: NSImage?

    var body: some View {
        let ref = main ?? secondaries.first
        let sw = ref?.sw ?? 1512, sh = ref?.sh ?? 982
        GeometryReader { geo in
            let scale = geo.size.width / sw
            ZStack(alignment: .topLeading) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().frame(width: geo.size.width, height: geo.size.height)
                    Color.black.opacity(0.3)
                } else {
                    Rectangle().fill(Color.black.opacity(0.55))
                }
                if let main { box(main, L("Phụ đề", "Subtitles"), .white, scale) }
                ForEach(Array(secondaries.enumerated()).filter { $0.element.displayID == (main?.displayID ?? $0.element.displayID) }, id: \.offset) { i, r in
                    box(r, L("Dịch màn hình \(i + 1)", "Screen translation \(i + 1)"), .orange, scale)
                }
            }
        }
        .aspectRatio(sw / max(1, sh), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.1)))
    }

    private func box(_ r: CaptureRegion, _ label: String, _ color: Color, _ scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.08)))
                .frame(width: max(4, r.w * scale), height: max(4, r.h * scale))
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.black.opacity(0.7), in: Capsule())
                .offset(y: -16)
        }
        .offset(x: r.x * scale, y: r.y * scale)
    }
}
