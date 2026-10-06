import SwiftUI
import Charts

@MainActor
final class DubPageState: ObservableObject {
    @Published var showGeminiInfo = false
    @Published var newName = ""
    @Published var newGender: Gender = .unknown
    @Published var testing = false
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

// MARK: Trang Lồng tiếng

struct DubSettingsPage: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    var body: some View { DubSettingsContent(tts: engine.tts, speaker: engine.speaker) }
}

private struct DubSettingsContent: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @ObservedObject var tts: GeminiTTS
    @ObservedObject var speaker: Speaker

    var body: some View {
        Form {
            Section {
                Toggle(L("Đọc to lời thoại", "Read dialogue aloud"), isOn: Binding(get: { settings.speakEnabled }, set: { settings.speakEnabled = $0 }))
                Note(L("Giọng đọc chỉ đọc lời thoại trong vùng phụ đề, kể cả khi bạn tắt Phụ đề. Chữ ở vùng dịch màn hình (menu, bảng nhiệm vụ) không được đọc.",
                       "Voice reads only the dialogue in the subtitle region, even with Subtitles turned off. Text in screen regions (menus, quest logs) is never read aloud."))
                Picker(L("Kiểu giọng", "Voice style"), selection: $settings.dubCharacters) {
                    Text(L("Voice-over · một giọng", "Voice-over · one voice")).tag(false)
                    Text(L("Dub · theo nhân vật (beta)", "Dub · per character (beta)")).tag(true)
                }
                .pickerStyle(.segmented)
                Note(settings.dubCharacters
                     ? L("Dub: mỗi nhân vật một giọng theo giới tính, tuổi. Cần game hiện tên người nói, xem hướng dẫn bên dưới. Câu nào chưa kịp dựng giọng trong 1 giây thì đọc bằng giọng Voice-over.", "Dub: each character gets a voice matched to gender and age. The game must show speaker names; see the guide below. If a character voice isn't ready within 1 second, the line is read in the Voice-over voice.")
                     : L("Voice-over: một giọng Siri đọc mọi câu, nhanh và đồng nhất. Trong game: \(HotkeyCenter.Action.toggleDub.display) bật/tắt, \(HotkeyCenter.Action.replayLast.display) đọc lại câu vừa rồi.", "Voice-over: one Siri voice reads every line, fast and consistent. In game: \(HotkeyCenter.Action.toggleDub.display) turns it on or off, \(HotkeyCenter.Action.replayLast.display) repeats the last line."))
                LabeledContent(L("Giọng Siri", "Siri voice")) {
                    Button(L("Nghe thử", "Preview")) { engine.previewVoice() }.buttonStyle(.glass)
                }
            } header: { Text(L("Giọng đọc", "Voice")) }

            Section {
                SliderRow(title: L("Âm lượng", "Volume"), value: Binding(get: { settings.speechVolume * 100 }, set: { settings.speechVolume = $0 / 100 }),
                          range: 0...100, step: 5, format: "%.0f%%")
                Toggle(L("Tự cân tốc độ theo nhịp thoại", "Match speed to dialogue pace"), isOn: $settings.autoSpeechRate)
                if !settings.autoSpeechRate {
                    SliderRow(title: L("Tốc độ", "Speed"), value: $settings.speechRate, range: 0.35...0.65, step: 0.01, format: "%.2f")
                }
                Toggle(L("Bỏ câu đã trễ quá xa", "Skip lines that fall too far behind"), isOn: $settings.dropStaleLines)
                Note(L("Câu cũ luôn được đọc hết, không bị cắt ngang. Câu chờ quá 6 giây mà đã có câu mới hơn thì bỏ, để giọng luôn bám theo màn hình.", "A line in progress is always finished, never cut off. A line that has waited more than 6 seconds while a newer one is ready is skipped, so the voice keeps up with the screen."))
                Toggle(L("Đọc theo cảm xúc của câu", "Read with the line's emotion"), isOn: $settings.dubEmotion)
                Note(L("Câu hét hay phấn khích đọc nhanh hơn, câu ngập ngừng hay buồn đọc chậm và nhỏ hơn. Dùng cho cả Voice-over lẫn Dub.",
                       "Shouted or excited lines are read faster; hesitant or sad lines slower and quieter. Applies to both Voice-over and Dub."))
            } header: { Text(L("Nhịp đọc", "Pacing")) }

            Section {
                Picker(L("Phát ra", "Output"), selection: $settings.dubDeviceUID) {
                    Text(L("Theo hệ thống", "System default")).tag("")
                    ForEach(AudioDevices.outputs()) { Text($0.name).tag($0.uid) }
                }
                Note(settings.dubDeviceUID.isEmpty
                     ? L("Chọn tai nghe riêng nếu muốn tiếng game vẫn ra loa. Lưu ý: phát ra loa riêng thì mỗi câu chậm hơn khoảng 1 giây.", "Pick separate headphones if you want game audio to stay on the speakers. Note: with a separate output, each line starts about 1 second later.")
                     : L("Đang phát ra loa riêng: mỗi câu chậm hơn khoảng 1 giây vì phải dựng âm thanh trước khi phát.", "Using a separate output: each line starts about 1 second later because the audio is rendered before it plays."))
                Toggle(L("Giảm tiếng game khi đang đọc (beta)", "Lower game audio while reading (beta)"), isOn: $settings.duckEnabled)
                if settings.duckEnabled {
                    SliderRow(title: L("Tiếng game còn", "Game audio level"), value: Binding(get: { settings.duckLevel * 100 }, set: { settings.duckLevel = $0 / 100 }),
                              range: 0...80, step: 5, format: "%.0f%%")
                    let gameName = settings.gameAppName.map { " (\($0))" } ?? ""
                    let duckError = speaker.ducker.lastError.map { L(" Lần gần nhất: \($0).", " Last error: \($0).") } ?? ""
                    Note(L("Chỉ giảm tiếng của app đang hiện game\(gameName) trong lúc đang đọc, các app khác giữ nguyên. Lần đầu macOS hỏi quyền ghi âm thanh hệ thống.\(duckError)",
                           "Only lowers the app showing the game\(gameName) while a line is being read; other apps are unaffected. The first time, macOS asks for permission to record system audio.\(duckError)"))
                }
            } header: { Text(L("Âm thanh", "Audio")) }

            Section {
                DisclosureGroup(L("Đổi giọng Siri", "Change the Siri voice")) {
                    let lang = settings.target.english
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("1. Mở System Settings → Accessibility → Read & Speak.", "1. Open System Settings → Accessibility → Read & Speak."))
                        Text(L("2. Bấm ⓘ cạnh System voice, chọn \(lang) ở danh sách bên trái.", "2. Click ⓘ next to System voice and choose \(lang) in the list on the left."))
                        Text(L("3. Bấm Voice rồi chọn giọng Siri. Giọng có biểu tượng đám mây thì tải về trước.", "3. Click Voice and pick a Siri voice. Voices with a cloud icon need to be downloaded first."))
                        Text(L("4. Quay lại đây, bấm Nghe thử.", "4. Come back here and click Preview."))
                    }
                    .font(.callout)
                    Button(L("Mở System Settings", "Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    Note(L("macOS chỉ cho app khác dùng giọng Siri đang được chọn cho mỗi ngôn ngữ, nên OverSub đọc bằng đúng giọng đó.", "macOS only lets other apps use the Siri voice currently selected for each language, so OverSub reads with that exact voice."))
                }
            }

            if settings.dubCharacters { dubSection }
        }
    }

    // MARK: Dub (theo nhân vật)

    private var namesSeen: Int { engine.recentNames.filter { $0 }.count }

    private var dubSection: some View {
        Section {
            step(1, done: namesSeen > 0, title: L("Bật hiện tên nhân vật trong game", "Turn on speaker names in the game"),
                 detail: L("Trong cài đặt của game, tìm mục kiểu \"Speaker Name\", \"Show Names\" hoặc \"Character Name in Subtitles\" và bật lên, để tên người nói hiện trong hộp thoại.", "In the game's settings, look for an option like \"Speaker Name\", \"Show Names\" or \"Character Name in Subtitles\" and turn it on so the speaker's name appears in the dialogue box."))
            step(2, done: namesSeen >= 3, title: L("Khung chọn bao cả nhãn tên và lời thoại", "Make the region cover both the name label and the dialogue"),
                 detail: engine.recentNames.isEmpty ? L("Chơi vài câu thoại để app kiểm tra.", "Play through a few lines so the app can check.")
                    : L("Trong \(engine.recentNames.count) câu gần nhất, app đọc được tên ở \(namesSeen) câu", "In the last \(engine.recentNames.count) lines, the app read a name in \(namesSeen)") + (engine.lastSpeaker.map { L(" (gần nhất: \($0))", " (latest: \($0))") } ?? "") + L(". Chưa thấy tên thì chọn lại vùng phụ đề và kéo rộng ra cho gồm cả nhãn tên.", ". If no names show up, reselect the subtitle region and widen it to include the name label."))
            let assigned = settings.cast.filter { !$0.isNarrator }
            step(3, done: !assigned.isEmpty, title: L("Kiểm tra giọng ở Dàn diễn viên", "Check the voices in Cast"),
                 detail: assigned.isEmpty ? L("Nhân vật sẽ tự hiện ở đây khi app đọc được tên.", "Characters appear here automatically once the app reads their names.") : L("Đã có \(assigned.count) nhân vật. Nghe thử và đổi giọng nếu chưa hợp.", "\(assigned.count) characters so far. Preview them and change any voice that doesn't fit."))
            Button(L("Mở Dàn diễn viên", "Open Cast")) { engine.openSettings(.cast) }
            Note(L("Câu hét đọc nhanh và to hơn, câu ngập ngừng hay buồn đọc chậm và nhỏ hơn. AI đoán giới tính, tuổi mỗi nhân vật mới (tốn thêm một lượt Groq hoặc Gemini).", "Shouted lines are read faster and louder; hesitant or sad lines slower and quieter. AI guesses the gender and age of each new character (uses one extra Groq or Gemini request)."))
            if speaker.dubFallbacks > 0 {
                Note(L("Phiên này có \(speaker.dubFallbacks) câu dựng giọng nhân vật không kịp, đã đọc bằng giọng Voice-over.", "This session, \(speaker.dubFallbacks) lines couldn't get a character voice in time and were read in the Voice-over voice."))
            }
        } header: { Text(L("Dub · theo nhân vật (beta)", "Dub · per character (beta)")) }
    }

    private func step(_ n: Int, done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title3).foregroundStyle(done ? Color.green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Note(detail)
            }
        }
    }
}

/// Tóm tắt hiệu suất Gemini TTS đo được trên máy này.
struct GeminiStatsSummary: View {
    @ObservedObject var tts: GeminiTTS
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            stat(L("Ra tiếng sau", "Time to audio"), tts.medianFirstAudio.map { String(format: "%.1f s", $0) } ?? "–")
            stat(L("Thành công", "Success rate"), tts.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
            stat(L("Lượt hôm nay", "Requests today"), "\(tts.callsToday)" + (tts.rateLimitedToday > 0 ? L(" · \(tts.rateLimitedToday) hết lượt", " · \(tts.rateLimitedToday) rate-limited") : ""))
            stat(settings.geminiTTSPaid ? L("Chi phí/giờ", "Cost/hour") : L("Key dùng được", "Usable API keys"), settings.geminiTTSPaid
                 ? String(format: "≈ $%.2f", tts.costPerLine(model: settings.geminiTTSModel) * 400)
                 : "\(tts.usableKeyCount)")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Bảng thông tin trước khi bật Gemini TTS

struct GeminiInfoSheet: View {
    @ObservedObject var tts: GeminiTTS
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = DubPageState()

    /// Số câu thoại mỗi giờ: đo theo buổi chơi hiện tại nếu đủ dữ liệu, không thì ước 400 câu (game nhiều thoại).
    private var linesPerHour: Double {
        let t = engine.transcript
        guard t.count >= 10, let a = t.first?.time, let b = t.last?.time, b.timeIntervalSince(a) > 120 else { return 400 }
        return min(1500, max(60, Double(t.count) / b.timeIntervalSince(a) * 3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text(L("Gemini TTS: chi phí và hiệu suất", "Gemini TTS: cost and performance")).font(.title3.weight(.semibold))
                    Text(L("Xem trước để quyết định dùng key miễn phí hay trả phí", "Review this before choosing a free or paid API key")).font(.callout).foregroundStyle(.secondary)
                }
            }

            comparison

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Mức tiêu thụ ước tính", "Estimated usage")).font(.headline)
                let lph = linesPerHour
                let cost = tts.costPerLine(model: settings.geminiTTSModel)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text(L("Câu thoại mỗi giờ chơi", "Lines per hour of play")).foregroundStyle(.secondary); Text("≈ \(Int(lph))") ; Text(engine.transcript.count >= 10 ? L("đo từ buổi chơi này", "measured this session") : L("ước cho game nhiều thoại", "estimate for a dialogue-heavy game")).font(.caption).foregroundStyle(.tertiary) }
                    GridRow { Text(L("Lượt gọi API mỗi giờ", "API requests per hour")).foregroundStyle(.secondary); Text("≈ \(Int(lph))"); Text(L("mỗi câu 1 lượt", "1 request per line")).font(.caption).foregroundStyle(.tertiary) }
                    GridRow { Text(L("Token âm thanh mỗi câu", "Audio tokens per line")).foregroundStyle(.secondary); Text("≈ \(Int(tts.tokensPerLine))"); Text(tts.okSamples.isEmpty ? L("số đo khi phát triển", "measured during development") : L("đo trên máy này", "measured on this Mac")).font(.caption).foregroundStyle(.tertiary) }
                    GridRow { Text(L("Key trả phí", "Paid API key")).foregroundStyle(.secondary)
                        Text(String(format: L("≈ $%.2f / giờ", "≈ $%.2f / hour"), cost * lph)).fontWeight(.semibold)
                        Text(String(format: L("$%.4f mỗi câu; giá gấp đôi từ 1/1/2027", "$%.4f per line; price doubles on Jan 1, 2027"), cost)).font(.caption).foregroundStyle(.tertiary) }
                    GridRow { Text(L("Key miễn phí", "Free API key")).foregroundStyle(.secondary)
                        Text(L("Giới hạn lượt mỗi ngày", "Daily request limit")).fontWeight(.semibold)
                        Text(L("Google không công bố con số cho model TTS; thường không đủ cho cả buổi chơi. Hết lượt thì tự đọc bằng giọng Apple.", "Google doesn't publish a number for TTS models; it usually isn't enough for a full play session. When the quota runs out, lines are read with the Apple voice.")).font(.caption).foregroundStyle(.tertiary) }
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Hiệu suất đo được", "Measured performance")).font(.headline)
                    Spacer()
                    Button(state.testing ? L("Đang đo…", "Testing…") : L("Đo thử 1 lượt", "Run a test")) { test() }.disabled(state.testing || tts.usableKeyCount == 0)
                }
                if tts.samples.isEmpty {
                    Text(tts.usableKeyCount == 0 ? L("Chưa có key Gemini. Thêm key ở Cài đặt → Dịch.", "No Gemini API key yet. Add one in Settings → Translation.") : L("Chưa có số liệu. Bấm Đo thử để đọc một câu mẫu (tốn 1 lượt) và xem độ trễ thật.", "No data yet. Click Run a test to read a sample line (uses 1 request) and see the real delay."))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Chart {
                        ForEach(Array(tts.samples.suffix(24).enumerated()), id: \.element.id) { i, s in
                            BarMark(x: .value(L("Lượt", "Request"), i + 1), y: .value(L("Giây", "Seconds"), s.firstAudio ?? s.total))
                                .foregroundStyle(s.ok ? Color.accentColor.gradient : Color.red.gradient)
                        }
                        RuleMark(y: .value(L("Chờ tối đa", "Max wait"), settings.geminiMaxWait))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text(L("quá mức này đọc bằng giọng Apple", "above this, the Apple voice takes over")).font(.caption2).foregroundStyle(.orange)
                            }
                    }
                    .chartYAxisLabel(L("giây tới khi ra tiếng", "seconds to first audio"))
                    .frame(height: 130)
                    if let e = tts.lastError { Text(L("Lỗi gần nhất: \(e)", "Latest error: \(e)")).font(.caption).foregroundStyle(.red) }
                }
            }

            Toggle(L("Key Gemini của tôi đã bật thanh toán (trả phí)", "My Gemini API key has billing enabled (paid)"), isOn: $settings.geminiTTSPaid)
                .font(.callout)

            HStack {
                Button(L("Dùng giọng Apple", "Use Apple voice")) {
                    settings.voiceSource = .apple
                    settings.geminiTTSIntroSeen = true
                    dismiss()
                }
                Spacer()
                Button(L("Bật Gemini TTS", "Turn on Gemini TTS")) {
                    settings.voiceSource = .gemini
                    settings.geminiTTSIntroSeen = true
                    dismiss()
                }
                .buttonStyle(.glassProminent).tint(Theme.accent)
                .disabled(tts.usableKeyCount == 0)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private var comparison: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("")
                Label("Apple", systemImage: "apple.logo").font(.callout.weight(.semibold))
                Label("Gemini TTS", systemImage: "sparkles").font(.callout.weight(.semibold))
            }
            Divider().gridCellColumns(3)
            row(L("Chi phí", "Cost"), L("Miễn phí", "Free"), settings.geminiTTSPaid ? String(format: L("≈ $%.2f / giờ", "≈ $%.2f / hour"), tts.costPerLine(model: settings.geminiTTSModel) * linesPerHour) : L("Miễn phí tới khi hết lượt", "Free until the quota runs out"))
            row(L("Độ trễ mỗi câu", "Delay per line"), L("Dưới 1 giây", "Under 1 second"), tts.medianFirstAudio.map { String(format: L("≈ %.1f giây (đo được)", "≈ %.1f s (measured)"), $0) } ?? L("≈ 5–6 giây (đo khi phát triển)", "≈ 5–6 s (measured during development)"))
            row(L("Số giọng tiếng Việt", "Vietnamese voices"), L("2 (đổi cao độ để phân biệt)", "2 (pitch-shifted to tell them apart)"), "30")
            row(L("Cảm xúc", "Emotion"), L("Mô phỏng bằng nhịp, cao độ", "Simulated with pacing and pitch"), L("Theo chỉ dẫn, tự nhiên hơn", "Directed, more natural"))
            row(L("Không cần mạng", "Works offline"), L("Có", "Yes"), L("Không", "No"))
        }
        .font(.callout)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ title: String, _ apple: String, _ gemini: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(apple)
            Text(gemini)
        }
    }

    private func test() {
        state.testing = true
        engine.testGemini()
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            state.testing = false
        }
    }
}

// MARK: Trang Dàn diễn viên

struct CastSettingsPage: View {
    @EnvironmentObject var engine: Engine
    var body: some View { CastSettingsContent(speaker: engine.speaker) }
}

private struct CastSettingsContent: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @ObservedObject var speaker: Speaker
    @StateObject private var state = DubPageState()

    private var appleOptions: [VoiceOption] {
        VoiceCatalog.apple(language: settings.target.base, siriGender: speaker.siriGender[settings.target.base] ?? .unknown)
    }

    var body: some View {
        Form {
            Section {
                Note(L("Mỗi nhân vật (đọc từ nhãn tên trên hộp thoại) tự có giọng theo giới tính, tuổi; AI đoán ở câu đầu. Bạn đổi giọng, cao độ ở đây; chỉnh tay thì app giữ nguyên lựa chọn. Danh sách lưu theo hồ sơ game. Đổi về Voice-over ở trang Giọng đọc.", "Each character (read from the name label on the dialogue box) automatically gets a voice by gender and age; AI guesses on their first line. Change voice and pitch here; once you edit by hand, the app keeps your choice. The list is saved per game profile. Switch back to Voice-over on the Voice page."))
            }

            Section {
                if !settings.cast.contains(where: { $0.isNarrator }) {
                    Button(L("Thêm người dẫn chuyện", "Add narrator")) { settings.cast.insert(.narrator, at: 0) }
                }
                ForEach(settings.cast) { m in CastRow(member: binding(m.id), speaker: speaker, options: appleOptions) }
            } header: {
                Text(L("Nhân vật (\(settings.cast.filter { !$0.isNarrator }.count))", "Characters (\(settings.cast.filter { !$0.isNarrator }.count))"))
            } footer: {
                Text(L("Giọng Apple cho \(settings.target.displayName): \(appleOptions.map(\.name).joined(separator: ", ")). Cao độ giúp các nhân vật dùng chung một giọng nghe khác nhau.",
                       "Apple voices for \(settings.target.displayName): \(appleOptions.map(\.name).joined(separator: ", ")). Pitch makes characters who share a voice sound different."))
            }

            Section {
                HStack {
                    TextField(L("Tên", "Name"), text: $state.newName, prompt: Text(L("Tên nhân vật, đúng như trên nhãn tên", "Character name, exactly as on the name label"))).labelsHidden()
                    Picker(L("Giới tính", "Gender"), selection: $state.newGender) {
                        ForEach(Gender.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button(L("Thêm", "Add")) { add() }.disabled(state.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text(L("Thêm nhân vật trước khi gặp", "Add a character ahead of time")) }
        }
    }

    private func binding(_ id: String) -> Binding<CastMember> {
        Binding(get: { settings.cast.first { $0.id == id } ?? .narrator },
                set: { v in if let i = settings.cast.firstIndex(where: { $0.id == id }), settings.cast[i] != v { settings.cast[i] = v } })
    }

    private func add() {
        let name = state.newName.trimmingCharacters(in: .whitespaces)
        let key = CastMember.key(for: name)
        guard !settings.cast.contains(where: { $0.id == key }) else { state.newName = ""; return }
        var m = CastMember(id: key, name: name, gender: state.newGender, classified: state.newGender != .unknown)
        CastDirector.autoAssign(&m, cast: settings.cast, apple: appleOptions)
        if !settings.cast.contains(where: { $0.isNarrator }) { settings.cast.insert(.narrator, at: 0) }
        settings.cast.append(m)
        state.newName = ""; state.newGender = .unknown
    }
}

/// Một nhân vật: dòng trên là tên và nút nghe thử; dòng dưới là các lựa chọn, mỗi lựa chọn có nhãn, độ rộng cố định nên không chen nhau.
private struct CastRow: View {
    @Binding var member: CastMember
    @ObservedObject var speaker: Speaker
    let options: [VoiceOption]
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine

    var body: some View {
        let m = member
        let speaking = speaker.isSpeaking && (m.isNarrator ? speaker.speakingName == nil : speaker.speakingName.map(CastMember.key) == m.id)
        let color: Color = m.gender == .male ? .blue : m.gender == .female ? .pink : .gray
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(color.gradient).frame(width: 30, height: 30)
                    if m.isNarrator { Image(systemName: "book.closed.fill").font(.caption).foregroundStyle(.white) }
                    else { Text(String(m.name.prefix(1)).uppercased()).font(.callout.weight(.bold)).foregroundStyle(.white) }
                }
                .overlay(Circle().stroke(Color.accentColor, lineWidth: speaking ? 2 : 0).padding(-3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.isNarrator ? L("Người dẫn chuyện", "Narrator") : m.name).font(.body.weight(.semibold))
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                if speaking { Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Color.accentColor) }
                Spacer()
                Button { engine.previewCast(m) } label: { Label(L("Nghe thử", "Preview"), systemImage: "play.fill") }
                    .buttonStyle(.glass).controlSize(.small)
                Menu {
                    if m.manual, !m.isNarrator {
                        Button(L("Để app tự chọn lại", "Let the app choose again")) {
                            var v = m; v.manual = false
                            CastDirector.autoAssign(&v, cast: settings.cast, apple: options)
                            member = v
                        }
                    }
                    if !m.isNarrator { Button(L("Xoá nhân vật", "Delete character"), role: .destructive) { settings.cast.removeAll { $0.id == m.id } } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(m.isNarrator)
                .opacity(m.isNarrator ? 0 : 1)
            }
            HStack(spacing: 16) {
                if !m.isNarrator {
                    field(L("Giới tính", "Gender")) {
                        Picker(L("Giới tính", "Gender"), selection: edit(\.gender)) { ForEach(Gender.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().frame(width: 92)
                    }
                    field(L("Tuổi", "Age")) {
                        Picker(L("Tuổi", "Age"), selection: edit(\.age)) { ForEach(AgeGroup.allCases) { Text($0.title).tag($0) } }
                            .labelsHidden().frame(width: 112)
                    }
                }
                field(L("Giọng", "Voice")) {
                    Picker(L("Giọng", "Voice"), selection: edit(\.appleVoice, default: VoiceCatalog.siriID)) {
                        ForEach(options) { o in Text(o.id == VoiceCatalog.siriID ? "Siri" : o.name).tag(o.id) }
                    }
                    .labelsHidden().frame(width: 120)
                }
                field(L("Cao độ", "Pitch")) {
                    HStack(spacing: 6) {
                        Button { setPitch(m.pitch - 1) } label: { Image(systemName: "minus") }.disabled(m.pitch <= -8)
                        Text(String(format: "%+.0f", m.pitch)).monospacedDigit().frame(width: 26)
                        Button { setPitch(m.pitch + 1) } label: { Image(systemName: "plus") }.disabled(m.pitch >= 8)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 40)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if member.isNarrator { return L("Câu không có nhãn tên", "Lines without a name label") }
        if member.manual { return L("Bạn đã chỉnh", "Edited by you") }
        return member.classified ? L("App tự chọn theo giới tính, tuổi", "Chosen by the app from gender and age") : L("Đang đoán giới tính, tuổi…", "Guessing gender and age…")
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            content()
        }
    }

    private func setPitch(_ v: Double) {
        guard v != member.pitch else { return }
        var m = member; m.pitch = max(-8, min(8, v)); m.manual = true; m.classified = true
        member = m
    }

    /// Chỉ đánh dấu "bạn đã chỉnh" khi giá trị thật sự đổi; Picker hay ghi lại đúng giá trị cũ khi vừa hiện.
    private func edit<T: Equatable>(_ kp: WritableKeyPath<CastMember, T>) -> Binding<T> {
        Binding(get: { member[keyPath: kp] }, set: { v in
            guard member[keyPath: kp] != v else { return }
            var m = member; m[keyPath: kp] = v; m.manual = true; m.classified = true
            member = m
        })
    }

    private func edit(_ kp: WritableKeyPath<CastMember, String?>, default def: String) -> Binding<String> {
        Binding(get: {
            let v = member[keyPath: kp] ?? def
            return options.contains { $0.id == v } ? v : def
        }, set: { v in
            guard (member[keyPath: kp] ?? def) != v else { return }
            var m = member; m[keyPath: kp] = v; m.manual = true; m.classified = true
            member = m
        })
    }
}
