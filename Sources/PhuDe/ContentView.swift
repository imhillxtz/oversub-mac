import SwiftUI

/// Tấm đặt tên khi lưu preset. Dùng ObservableObject thay cho @State (SDK mới biến @State thành macro, mà Command Line Tools
/// không có plugin SwiftUIMacros).
@MainActor
final class PresetNameForm: ObservableObject {
    @Published var show = false
    @Published var name = ""
}

/// Cửa sổ chính: thuyết minh là trung tâm. Nút thuyết minh lớn, câu đang đọc sáng dần theo giọng, bảng âm thanh ngay bên dưới.
/// Phụ đề xem ở "Cửa sổ phụ đề" (cửa sổ riêng, đặt được ở màn hình thứ hai).
struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var hub: TranslationHub
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @StateObject private var presetForm = PresetNameForm()
    @ObservedObject private var subtitles = SubtitleWindowState.shared
    @ObservedObject private var updater = Updater.shared
    @StateObject private var presence = WindowPresence()
    @ObservedObject private var support = SupportPrompt.shared

    var body: some View {
        VStack(spacing: 0) {
            if let problem = engine.problem {
                problemBanner(problem)
                    .padding([.horizontal, .top], 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            VoiceOverStage(speaker: engine.speaker, openSubtitles: { SubtitleWindowState.shared.show() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        // Nền gradient trôi chậm, rực hơn khi phiên đang chạy; chạy lên cả dưới thanh công cụ cho liền một mảng.
        .background { HomeBackdrop(vivid: engine.anyRunning) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.smooth(duration: 0.3), value: engine.problem)
        .animation(.smooth(duration: 0.3), value: support.pending)
        .animation(.smooth(duration: 0.3), value: updater.pending)
        .animation(.smooth(duration: 0.25), value: settings.speakEnabled)
        // Lịch sử thoại nổi đè lên phía phải, không chiếm chỗ: trước đây là cột bên (inspector) ép nội dung chính co lại,
        // cửa sổ hẹp thì thanh công cụ và chữ bị cắt.
        .overlay(alignment: .topTrailing) {
            if engine.showHistory {
                HistoryView(onClose: { engine.showHistory = false })
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: engine.showHistory)
        .toolbar { toolbarContent }
        .sheet(isPresented: $presetForm.show.deduplicated) { PresetSaveSheet(form: presetForm) }
        .sheet(isPresented: Binding(get: { !settings.onboardingDone }, set: { if !$0 && !settings.onboardingDone { settings.onboardingDone = true } })) {
            OnboardingView()
        }
        .onAppear {
            // Menu trên thanh menu (AppKit) mượn hành động mở cửa sổ của SwiftUI.
            let window = openWindow, prefs = openSettings
            StatusMenu.openMain = { window(id: "main") }
            StatusMenu.openDonate = { window(id: "donate") }
            StatusMenu.openSettings = { prefs() }
        }
        .onChange(of: engine.requestedSettingsPage) { _, page in
            if page != nil { openSettings() }
        }
        // Cửa sổ bị game che hay app bị ẩn thì các hoạt ảnh ở màn hình chính dừng hẳn.
        .background(WindowPresenceReader(presence: presence))
        .environment(\.homeAnimating, presence.visible)
    }

    // MARK: Thanh công cụ

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { engine.toggleRunning() } label: {
                Label(engine.anyRunning ? L("Dừng", "Stop") : L("Bắt đầu", "Start"), systemImage: engine.anyRunning ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.glassProminent)
            .tint(engine.anyRunning ? .red : Theme.accent)
            .help(L("Bắt đầu hoặc dừng tất cả: phụ đề và dịch màn hình (⌘R · trong game: \(HotkeyCenter.Action.toggleRunning.display))", "Start or stop everything: subtitles and screen translation (⌘R · in game: \(HotkeyCenter.Action.toggleRunning.display))"))
        }
        ToolbarSpacer(.fixed, placement: .navigation)
        ToolbarItem(placement: .navigation) {
            Button { engine.selectRegion() } label: { Label(L("Chọn vùng phụ đề", "Select subtitle region"), systemImage: "viewfinder") }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help(L("Chọn vùng phụ đề lời thoại (xem lại rồi lưu) · ⌘K · trong game \(HotkeyCenter.Action.selectRegion.display)", "Select the region where dialogue subtitles appear (review, then save) · ⌘K · in game \(HotkeyCenter.Action.selectRegion.display)"))
        }
        // Hai nút ngang hàng, dùng chung một trình chọn vùng; trạng thái đang dịch màn hình hiện ở chân cửa sổ.
        ToolbarItem(placement: .navigation) {
            Button { engine.selectRegion(screen: true) } label: { Label(L("Thêm vùng dịch", "Add screen region"), systemImage: "text.viewfinder") }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help(L("Kéo khung quanh chữ ngoài lời thoại (bảng nhiệm vụ, menu, mô tả vật phẩm) để dịch ngay tại chỗ, tối đa \(RegionEditor.maxSecondaries) vùng · bật/tắt \(HotkeyCenter.Action.screenTranslate.display)", "Drag a box around non-dialogue text (quest logs, menus, item descriptions) to translate it in place, up to \(RegionEditor.maxSecondaries) regions · toggle with \(HotkeyCenter.Action.screenTranslate.display)"))
        }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            Button { subtitles.toggle() } label: {
                Label(L("Cửa sổ phụ đề", "Subtitle window"), systemImage: subtitles.isOpen ? "macwindow.badge.plus" : "macwindow")
            }
            .help(subtitles.isOpen ? L("Đóng Cửa sổ phụ đề (⌘J)", "Close the subtitle window (⌘J)") : L("Mở Cửa sổ phụ đề: cửa sổ riêng chỉ có câu thoại, thu được còn một dòng (⌘J)", "Open the subtitle window: a separate window with just the dialogue, shrinkable to a single line (⌘J)"))
        }
        ToolbarItem(placement: .primaryAction) { presetMenu }
        ToolbarItem(placement: .primaryAction) {
            Button { engine.showHistory.toggle() } label: { Label(L("Lịch sử", "History"), systemImage: "clock.arrow.circlepath") }
                .help(L("Xem lại các câu vừa qua (⌘L · trong game: \(HotkeyCenter.Action.history.display))", "Review recent lines (⌘L · in game: \(HotkeyCenter.Action.history.display))"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openSettings() } label: { Label(L("Cài đặt", "Settings"), systemImage: "gearshape") }
                .help(L("Cài đặt (⌘,)", "Settings (⌘,)"))
        }
    }

    /// Menu hồ sơ game: chuyển nhanh, tạo hồ sơ mới. Mọi thay đổi tự lưu vào hồ sơ đang dùng.
    private var presetMenu: some View {
        Menu {
            ForEach(settings.presets) { p in
                Button { engine.applyPreset(p) } label: {
                    if p.id == settings.activePresetID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button(L("Tạo hồ sơ mới cho game khác…", "New profile for another game…")) {
                presetForm.name = settings.gameAppName.map { L("\($0) (mới)", "\($0) (new)") } ?? L("Hồ sơ \(settings.presets.count + 1)", "Profile \(settings.presets.count + 1)")
                presetForm.show = true
            }
            Button(L("Quản lý hồ sơ…", "Manage profiles…")) { engine.openSettings(.presets) }
        } label: {
            Label(settings.activePreset?.name ?? L("Hồ sơ", "Profile"), systemImage: "square.stack.3d.up")
                .labelStyle(.titleAndIcon)
        }
        .labelStyle(.titleAndIcon)
        .help(L("Hồ sơ game: mỗi game một bộ cài đặt và trí nhớ riêng, tự lưu", "Game profiles: each game gets its own settings and memory, saved automatically"))
    }

    /// Có bản mới: gói trong dòng trạng thái ở chân cửa sổ, không đẩy nội dung (thông báo nổi phía trên làm hàng chip bị cắt
    /// khi cửa sổ thấp). Bấm Cập nhật là tải, kiểm chữ ký, cài và mở lại; "Để sau" thì không nhắc bản này nữa.
    private func updateNotice(_ r: Updater.Release) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
            Group {
                if case .downloading(_, let p) = updater.state { Text(L("Đang tải bản \(r.version)… \(Int(p * 100))%", "Downloading \(r.version)… \(Int(p * 100))%")) }
                else if case .installing = updater.state { Text(L("Đang cài bản \(r.version), app sẽ tự mở lại…", "Installing \(r.version); the app will reopen…")) }
                else if case .failed(let m) = updater.state { Text(m) }
                else { Text(L("Có bản mới \(r.version)", "Version \(r.version) is available")).fontWeight(.semibold) }
            }
            .lineLimit(1).monospacedDigit()
            Link(L("Có gì mới", "What's new"), destination: r.page)
            Button(L("Để sau", "Later")) { updater.dismissedVersion = r.version }.buttonStyle(.link)
            Button { updater.updateNow() } label: {
                Text(L("Cập nhật", "Update")).fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.gradient))
            }
            .buttonStyle(.plain)
            .disabled({ if case .downloading = updater.state { return true }; if case .installing = updater.state { return true }; return false }())
        }
        .font(.caption)
    }

    /// Lời cảm ơn khi số câu đã dịch vượt mốc, nằm trong dòng trạng thái ở chân cửa sổ như thông báo bản mới (thẻ riêng ở đầu
    /// cửa sổ đẩy hàng chip ở chân ra ngoài khi cửa sổ thấp). Bấm Ủng hộ mở cửa sổ Ủng hộ; Để sau thì không nhắc mốc này nữa.
    private func supportNotice(_ m: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill").foregroundStyle(.pink)
            (Text(L("OverSub đã dịch hơn \(Donation.count(m)) câu thoại cho bạn. ", "OverSub has translated over \(Donation.count(m)) lines for you. ")).fontWeight(.semibold)
             + Text(L("Mong là app giúp bạn chơi vui hơn.", "I hope it's made your games more fun.")).foregroundStyle(.secondary))
                .lineLimit(1)
            Button(L("Để sau", "Later")) { support.dismiss() }.buttonStyle(.link)
            Button {
                support.dismiss()
                openWindow(id: "donate")
            } label: {
                Text(L("Ủng hộ", "Support")).fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.gradient))
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }

    private func problemBanner(_ problem: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(problem).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if problem.contains("quyền") || problem.localizedCaseInsensitiveContains("permission") {
                Button(L("Mở cấp quyền", "Open Privacy Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Chân cửa sổ

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let r = updater.pending, updater.dismissedVersion != r.version {
                    updateNotice(r).transition(.opacity)
                } else if let m = support.pending, !engine.anyRunning, settings.onboardingDone {
                    // Chỉ hiện lúc không chơi; bản mới (ở trên) được ưu tiên.
                    supportNotice(m).transition(.opacity)
                } else {
                    Text(engine.status)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.smooth, value: engine.status)
                }
                Spacer(minLength: 8)
                // Lối vào cửa sổ Ủng hộ: luôn có nhưng nhỏ, không tranh chú ý với các nút chính (ẩn khi lời cảm ơn đang hiện).
                if support.pending == nil || engine.anyRunning {
                Button { openWindow(id: "donate") } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                        Text(L("Ủng hộ", "Support")).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Ủng hộ OverSub: quét VietQR hoặc PayPal", "Support OverSub via VietQR or PayPal"))
                }
            }
            .frame(height: 18)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    engineChip
                    chipMenu(icon: "globe", text: "→ " + settings.target.displayName) {
                        ForEach(TargetLanguage.all) { t in
                            Button { settings.targetLanguage = t.code } label: {
                                if t.code == settings.targetLanguage { Label(t.displayName, systemImage: "checkmark") } else { Text(t.displayName) }
                            }
                        }
                    }
                    .help(L("Ngôn ngữ dịch sang", "Target language"))
                    chipMenu(icon: "text.bubble", text: settings.mode.title) {
                        ForEach(DisplayMode.allCases) { m in
                            Button { settings.mode = m } label: {
                                if m == settings.mode { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                            }
                        }
                    }
                    .help(L("Đọc và hiện gì: bản dịch, kèm câu gốc, hoặc chỉ đọc to câu gốc", "What to show and read: the translation, the translation with the original, or just the original read aloud"))
                    chipMenu(icon: "theatermasks", text: settings.genre.title.components(separatedBy: " (").first ?? "") {
                        ForEach(GameGenre.allCases) { g in
                            Button { settings.genre = g } label: {
                                if g == settings.genre { Label(g.title, systemImage: "checkmark") } else { Text(g.title) }
                            }
                        }
                    }
                    .help(L("Thể loại game: quyết định xưng hô và giọng văn", "Game genre: sets forms of address and tone"))
                    Spacer(minLength: 4)
                    // Âm lượng giọng đọc nằm cùng hàng với các chip, bên phải (chỉ hiện khi bật giọng đọc).
                    if settings.speakEnabled {
                        AudioPanel(speaker: engine.speaker)
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var engineChip: some View {
        let label = hub.activeLabel
                let ok = hub.activeOK
        return Button { engine.openSettings(.translate) } label: {
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(label.components(separatedBy: " (key").first ?? label).lineLimit(1)
            }
            .footerChip()
        }
        .buttonStyle(.plain)
        .help(L("Dịch vụ đang dịch. Bấm để xem trạng thái các dịch vụ.", "The service translating right now. Click to see the status of every service."))
    }

    private func chipMenu<Content: View>(icon: String, text: String, @ViewBuilder content: () -> Content) -> some View {
        // Kiểu nút thường với nhãn tự vẽ: menu kiểu mặc định của hệ thống không nhận cỡ chữ, nên chip to nhỏ không đều.
        Menu { content() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(text).lineLimit(1)
            }
            .footerChip()
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: Sân khấu: Sub & giọng đọc

/// Phần giữa cửa sổ: nút Phụ đề, linh vật (giọng đọc) ở giữa, nút Dịch màn hình; câu đang đọc hiện như phụ đề trên game, sáng dần theo giọng.
struct VoiceOverStage: View {
    @ObservedObject var speaker: Speaker
    var openSubtitles: () -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            // Ba tính năng bật/tắt độc lập; nút Bắt đầu chạy cả phiên.
            // Ba cột cân đối, linh vật (giọng đọc) lớn ở giữa. Phụ đề và giọng đọc cùng lo lời thoại (chung vùng phụ đề) nên được
            // nối với nhau bằng một dải kính mảnh phía sau; dịch màn hình đứng riêng.
            HStack(alignment: .top, spacing: 40) {
                HStack(alignment: .top, spacing: 40) {
                    SubButton()
                    MascotButton(speaker: speaker)
                }
                .background(alignment: .top) {
                    // Ống chạy từ mép nút Phụ đề tới mép linh vật (lấn vào dưới mỗi bên một chút cho liền).
                    EnergyLink(enabled: settings.speakEnabled, active: engine.running && settings.speakEnabled, speaking: settings.speakEnabled && speaker.isSpeaking)
                        .padding(.leading, orbColumn / 2 + 44)
                        .padding(.trailing, orbColumn / 2 + 58)
                        .offset(y: (orbRowHeight - 10) / 2)
                }
                ScreenTranslateButton()
            }
            lineArea
                .frame(maxWidth: 660)
                .padding(.horizontal, 24)
            Spacer(minLength: 8)
        }
    }

    private var hasLine: Bool { !engine.lastTranslation.isEmpty || !engine.lastSource.isEmpty }

    @ViewBuilder
    private var lineArea: some View {
        if hasLine {
            VStack(spacing: 8) {
                // Hiện như phụ đề trên game (nền tối, chữ sáng): đúng tinh thần OverSub.
                VStack(spacing: 6) {
                    if let s = engine.lastSpeaker {
                        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                    }
                    KaraokeText(speaker: speaker,
                                text: engine.lastTranslation.isEmpty ? engine.lastSource : engine.lastTranslation,
                                size: min(settings.windowFontSize, 30), onDark: true)
                    if settings.windowShowsOriginal, !engine.lastTranslation.isEmpty, !engine.lastSource.isEmpty {
                        Text(engine.lastSource)
                            .font(.system(size: min(settings.windowFontSize, 30) * 0.55))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(3)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
                HStack(spacing: 16) {
                    Button { engine.replayLast() } label: { Label(L("Đọc lại", "Replay"), systemImage: "arrow.counterclockwise") }
                        .help(L("Đọc lại câu vừa rồi (\(HotkeyCenter.Action.replayLast.display))", "Replay the last line (\(HotkeyCenter.Action.replayLast.display))"))
                    Button { engine.ignoreCurrentSentence() } label: { Label(L("Bỏ qua câu này", "Ignore this line"), systemImage: "text.badge.xmark") }
                        .help(L("Từ nay không dịch, không đọc câu này nữa (logo, chữ cố định trên màn hình...)", "Never translate or read this text again (logos, fixed on-screen text…)"))
                    Button { engine.showTermPicker = true } label: { Label(L("Giữ nguyên tên riêng…", "Keep a name untranslated…"), systemImage: "textformat.abc") }
                        .popover(isPresented: $engine.showTermPicker.deduplicated) { TermPicker() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .transition(.opacity)
        } else {
            guidance.transition(.opacity)
        }
    }

    /// Chưa có câu nào: một nút hành động chính to, rõ, và một dòng gợi ý nhỏ bên dưới.
    @ViewBuilder
    private var guidance: some View {
        VStack(spacing: 10) {
            if engine.screenTranslateOn && !engine.running {
                // Chỉ dịch màn hình đang chạy (chưa có hoặc chưa bật phụ đề lời thoại).
                Label(L("Đang dịch màn hình · \(settings.secondaryRegions.count) vùng", "Translating screen · \(settings.secondaryRegions.count) regions"), systemImage: "text.viewfinder")
                    .font(.callout).foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
                if settings.region == nil {
                    Text(L("Để có phụ đề lời thoại, bạn bấm Chọn vùng phụ đề · \(HotkeyCenter.Action.selectRegion.display)", "For dialogue subtitles, click Select subtitle region · \(HotkeyCenter.Action.selectRegion.display)")).font(.caption).foregroundStyle(.tertiary)
                }
            } else if settings.region == nil && settings.secondaryRegions.isEmpty {
                Button { engine.selectRegion() } label: {
                    Label(L("Chọn vùng phụ đề", "Select subtitle region"), systemImage: "viewfinder")
                }
                .buttonStyle(SecondaryCTAStyle())
                Text(L("Kéo quanh chỗ phụ đề hiện ra trong game · \(HotkeyCenter.Action.selectRegion.display)", "Drag around where subtitles appear in the game · \(HotkeyCenter.Action.selectRegion.display)")).font(.caption).foregroundStyle(.secondary)
            } else if !engine.anyRunning {
                Button { engine.startAll() } label: { Label(L("Bắt đầu", "Start"), systemImage: "play.fill") }
                    .buttonStyle(CTAButtonStyle())
                Text(L("⌘R · hoặc \(HotkeyCenter.Action.toggleRunning.display) ngay trong game", "⌘R · or \(HotkeyCenter.Action.toggleRunning.display) right in the game")).font(.caption).foregroundStyle(.secondary)
            } else if !engine.gameInFront {
                Label(L("Đang chờ \(settings.gameAppName ?? "game") trở lại phía trước", "Waiting for \(settings.gameAppName ?? "game") to come back to the front"), systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label(L("Đang chờ câu thoại…", "Waiting for dialogue…"), systemImage: "ellipsis.bubble")
                    .font(.callout).foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 14)
    }
}

/// Nút lớn bật/tắt phụ đề đè lên game (Sub).
struct SubButton: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine

    var body: some View {
        let on = settings.overlayEnabled
        VStack(spacing: 8) {
            Button { engine.toggleOverlay() } label: {
                Image(systemName: on ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(on ? .white : .secondary)
                    .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 2, y: 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(GlassOrbStyle(on: on, active: engine.running))
            .frame(height: orbRowHeight)
            VStack(spacing: 2) {
                Text(L("Phụ đề", "Subtitles")).font(.headline)
                Text(on ? L("Hiện lời thoại · \(HotkeyCenter.Action.toggleOverlay.display)", "Shows dialogue · \(HotkeyCenter.Action.toggleOverlay.display)") : L("Đang tắt · \(HotkeyCenter.Action.toggleOverlay.display)", "Off · \(HotkeyCenter.Action.toggleOverlay.display)")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: orbColumn)
        .animation(.smooth(duration: 0.3), value: on)
        .help(on ? L("Ẩn phụ đề đè lên game (\(HotkeyCenter.Action.toggleOverlay.display))", "Hide the subtitle overlay (\(HotkeyCenter.Action.toggleOverlay.display))") : L("Hiện phụ đề đè lên game (\(HotkeyCenter.Action.toggleOverlay.display))", "Show subtitles over the game (\(HotkeyCenter.Action.toggleOverlay.display))"))
    }
}

/// Chiều cao hàng nút tròn: bằng nút giọng đọc (nút lớn ở giữa); hai nút bên nhỏ hơn và canh giữa theo chiều dọc.
let orbRowHeight: CGFloat = 128
/// Bề ngang mỗi cột nút tròn (nút và chữ bên dưới), cố định để ba cột cân đối tuyệt đối.
let orbColumn: CGFloat = 150

/// Nút lớn bật/tắt dịch màn hình: dịch tại chỗ chữ ngoài lời thoại (menu, bảng nhiệm vụ, mô tả vật phẩm).
struct ScreenTranslateButton: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine

    var body: some View {
        let on = settings.screenTranslateEnabled
        let n = settings.secondaryRegions.count
        VStack(spacing: 8) {
            Button { engine.toggleScreenTranslate() } label: {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(on ? .white : .secondary)
                    .shadow(color: .black.opacity(on ? 0.18 : 0), radius: 2, y: 1)
            }
            .buttonStyle(GlassOrbStyle(on: on, active: engine.screenTranslateOn))
            .frame(height: orbRowHeight)
            VStack(spacing: 2) {
                Text(L("Dịch màn hình", "Screen translation")).font(.headline)
                Text(n == 0 ? L("Chưa có vùng · \(HotkeyCenter.Action.screenTranslate.display)", "No regions yet · \(HotkeyCenter.Action.screenTranslate.display)") : on ? (engine.screenTranslateOn ? L("Đang dịch \(n) vùng · \(HotkeyCenter.Action.screenTranslate.display)", "Translating \(n) regions · \(HotkeyCenter.Action.screenTranslate.display)") : L("Dịch menu, nhiệm vụ · \(HotkeyCenter.Action.screenTranslate.display)", "Menus, quests · \(HotkeyCenter.Action.screenTranslate.display)")) : L("Đang tắt · \(HotkeyCenter.Action.screenTranslate.display)", "Off · \(HotkeyCenter.Action.screenTranslate.display)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: orbColumn)
        .animation(.smooth(duration: 0.3), value: on)
        .help(n == 0 ? L("Thêm vùng quanh menu, bảng nhiệm vụ để dịch ngay tại chỗ (\(HotkeyCenter.Action.screenTranslate.display))", "Add a region around menus or quest logs to translate them in place (\(HotkeyCenter.Action.screenTranslate.display))")
              : on ? L("Tắt dịch màn hình (\(HotkeyCenter.Action.screenTranslate.display))", "Turn off screen translation (\(HotkeyCenter.Action.screenTranslate.display))") : L("Bật dịch màn hình: dịch tại chỗ menu, bảng nhiệm vụ, mô tả vật phẩm (\(HotkeyCenter.Action.screenTranslate.display))", "Turn on screen translation: menus, quest logs and item descriptions translated in place (\(HotkeyCenter.Action.screenTranslate.display))"))
    }
}

/// Câu đang đọc, phần đã đọc sáng rõ, phần chưa đọc mờ. Đọc thẳng thì theo từng từ Siri báo; đọc qua bộ đệm thì ước theo thời gian.
struct KaraokeText: View {
    @ObservedObject var speaker: Speaker
    let text: String
    let size: Double
    var onDark = false
    var lines = 5
    /// Tên người nói đứng đầu dòng, cùng một khối chữ nên co giãn cùng cỡ với câu thoại.
    var name: String? = nil

    var body: some View {
        let ns = text as NSString
        let reading = speaker.currentText == text && speaker.isSpeaking
        let end = reading ? min(max(0, speaker.spokenEnd), ns.length) : ns.length
        let done = ns.substring(to: end), rest = ns.substring(from: end)
        let lead = name.map { Text($0 + ":  ").foregroundStyle(onDark ? Color.white.opacity(0.6) : Color.secondary) } ?? Text("")
        (lead
            + Text(done).foregroundStyle(onDark ? Color.white : Color.primary)
            + Text(rest).foregroundStyle(onDark ? Color.white.opacity(0.38) : Color.secondary.opacity(0.55)))
            .font(.system(size: size, weight: .semibold))
            .lineLimit(lines)
            .minimumScaleFactor(lines == 1 ? 0.5 : 0.6)
            .animation(.smooth(duration: 0.18), value: end)
    }
}

/// Gợi ý tên riêng trong câu đang hiện để giữ nguyên, không dịch.
struct TermPicker: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        let found = engine.termCandidates()
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Chọn tên để giữ nguyên, không dịch", "Pick names to keep untranslated")).font(.headline)
            if found.isEmpty {
                Text(L("Câu này không có tên riêng nào mới. Bạn có thể thêm tên bằng tay ở Cài đặt → Văn phong & thuật ngữ.", "No new names found in this line. Add one manually in Settings → Style & glossary."))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 260, alignment: .leading)
            }
            ForEach(found, id: \.self) { name in
                Button { engine.addTermToGlossary(name) } label: { Label(name, systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(14)
    }
}

// MARK: Bảng âm thanh

@MainActor
final class AudioPanelState: ObservableObject {
    @Published var showOptions = false
}

/// Thanh giọng đọc ở cửa sổ chính (chỉ hiện khi bật Voice-over/Dub): âm lượng và Nghe thử; tốc độ, loa phát, giảm tiếng game
/// nằm trong nút Tuỳ chọn để màn hình chính gọn.
struct AudioPanel: View {
    @ObservedObject var speaker: Speaker
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @StateObject private var state = AudioPanelState()

    var body: some View {
        // Viên thuốc gọn ở cuối hàng chân cửa sổ: âm lượng, nghe thử, tuỳ chọn. Cao bằng các chip bên cạnh.
        HStack(spacing: 8) {
            Image(systemName: settings.speechVolume == 0 ? "speaker.slash.fill" : settings.speechVolume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            SlimSlider(value: $settings.speechVolume)
                .frame(width: 120)
                .help(L("Âm lượng giọng đọc: \(Int(settings.speechVolume * 100))%", "Voice volume: \(Int(settings.speechVolume * 100))%"))
            Divider().frame(height: 14)
            Button { engine.previewVoice() } label: { Image(systemName: "play.fill").font(.system(size: 11)) }
                .buttonStyle(.borderless)
                .help(L("Nghe thử giọng đọc", "Preview the voice"))
            Button { state.showOptions.toggle() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 12)) }
                .buttonStyle(.borderless)
                .help(L("Giọng Siri, tốc độ đọc, loa phát, giảm tiếng game", "Siri voice, speed, output, game ducking"))
                .popover(isPresented: $state.showOptions.deduplicated, arrowEdge: .top) {
                    AudioOptions().padding(16).frame(width: 380)
                }
        }
        .footerChip()
    }
}

extension View {
    /// Kiểu chung cho mọi chip ở chân cửa sổ: cùng cỡ chữ, cùng chiều cao, cùng lề, cùng nền kính.
    func footerChip() -> some View {
        self.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .glassEffect(.regular, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Tuỳ chọn giọng đọc (bấm nút trên thanh giọng đọc): mỗi dòng một tên và một điều khiển, canh thẳng hàng.
private struct AudioOptions: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Tuỳ chọn giọng đọc", "Voice options")).font(.headline)
            SiriVoiceGuide(compact: true)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(L("Tốc độ", "Speed")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L("Tự cân theo nhịp thoại", "Match the pace of dialogue"), isOn: $settings.autoSpeechRate).toggleStyle(.switch).controlSize(.small)
                        if !settings.autoSpeechRate {
                            HStack {
                                Slider(value: Binding(get: { settings.speechRate }, set: { settings.speechRate = ($0 * 100).rounded() / 100 }), in: 0.35...0.65)
                                    .controlSize(.small)
                                Text(String(format: "%.0f%%", settings.speechRate / 0.5 * 100)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
                GridRow {
                    Text(L("Phát ra", "Output")).foregroundStyle(.secondary)
                    Picker(L("Phát ra", "Output"), selection: $settings.dubDeviceUID) {
                        Text(L("Theo hệ thống", "System default")).tag("")
                        ForEach(AudioDevices.outputs()) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .help(settings.dubDeviceUID.isEmpty ? L("Chọn tai nghe riêng nếu muốn tiếng game vẫn ra loa", "Pick separate headphones to keep game audio on the speakers") : L("Phát ra loa riêng: mỗi câu chậm hơn khoảng 1 giây", "Separate output device: each line starts about 1 second later"))
                }
                GridRow {
                    Text(L("Tiếng game", "Game audio")).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L("Giảm khi đang đọc", "Lower while speaking"), isOn: $settings.duckEnabled).toggleStyle(.switch).controlSize(.small)
                        if settings.duckEnabled {
                            HStack {
                                Slider(value: Binding(get: { settings.duckLevel }, set: { settings.duckLevel = ($0 * 20).rounded() / 20 }), in: 0...0.8)
                                    .controlSize(.small)
                                Text(L("còn \(Int(settings.duckLevel * 100))%", "to \(Int(settings.duckLevel * 100))%")).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                    }
                    .help(L("Thử nghiệm: giảm tiếng của app đang hiện game\(settings.gameAppName.map { " (\($0))" } ?? "") trong lúc đang đọc. Lần đầu macOS hỏi quyền ghi âm thanh hệ thống.",
                            "Experimental: lowers the audio of the app showing the game\(settings.gameAppName.map { " (\($0))" } ?? "") while a line is spoken. The first time, macOS asks for permission to record system audio."))
                }
            }
            .font(.callout)
            Text(L("Giọng đọc, Dub theo nhân vật và hướng dẫn giọng Siri ở Cài đặt → Giọng đọc.", "Voices, per-character Dub and the Siri voice guide are in Settings → Voice."))
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tấm tạo hồ sơ mới cho game khác: dùng cài đặt hiện tại, trí nhớ game bắt đầu trống.
struct PresetSaveSheet: View {
    @ObservedObject var form: PresetNameForm
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("Tạo hồ sơ game mới", "New game profile"), systemImage: "square.stack.3d.up").font(.title3.weight(.semibold))
            TextField(L("Tên hồ sơ", "Profile name"), text: $form.name, prompt: Text(L("Tên game, ví dụ Monster Hunter Stories 3", "Game name, e.g. Monster Hunter Stories 3")))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Lấy từ cài đặt hiện tại", "Copied from current settings")).font(.callout.weight(.semibold))
                row("viewfinder", settings.region.map { L("Khung \(Int($0.w))×\(Int($0.h))", "Region \(Int($0.w))×\(Int($0.h))") + (settings.gameAppName.map { " · \($0)" } ?? "") } ?? L("Chưa chọn vùng", "No region selected"))
                row("globe", L("Dịch sang \(settings.target.displayName)", "Translate to \(settings.target.displayName)") + " · \(settings.genre.title.components(separatedBy: " (").first ?? "")")
                row("captions.bubble", L("Phụ đề, giọng đọc, bắt thoại, dịch vụ dịch", "Subtitles, voice, dialogue capture, translation services"))
                Divider().padding(.vertical, 2)
                Text(L("Bắt đầu trống", "Starts empty")).font(.callout.weight(.semibold))
                row("brain", L("Ngữ cảnh hội thoại, dàn diễn viên, thuật ngữ, câu luôn bỏ qua, bộ nhớ dịch", "Conversation context, cast, glossary, ignored lines, translation memory"))
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text(L("Nếu là cùng một game (ví dụ một bản lưu khác) và bạn muốn giữ trí nhớ dịch, hãy dùng Nhân bản ở trang Hồ sơ game. Mọi thay đổi sau đó tự lưu vào hồ sơ đang dùng.", "To keep the memory for the same game (another save file, say), use Duplicate on the Game profiles page. Later changes are saved to the active profile automatically."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Huỷ", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Tạo hồ sơ", "Create profile")) {
                    engine.createProfile(named: form.name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent).tint(Theme.accent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.callout)
    }
}
