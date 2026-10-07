import SwiftUI
import Translation
import AppKit
import UniformTypeIdentifiers

/// Ô dán key + nút kiểm tra. Dùng ObservableObject thay cho @State (xem ghi chú ở Engine).
@MainActor
final class KeyForm: ObservableObject {
    let provider: EngineKind
    @Published var input = ""
    @Published var message = ""
    @Published var ok = true
    @Published var checking = false

    init(provider: EngineKind) { self.provider = provider }

    func submit(hub: TranslationHub) {
        guard !checking else { return }
        checking = true
        ok = true
        message = L("Đang kiểm tra…", "Checking…")
        let secret = input
        Task {
            let r = await hub.addKey(provider, secret: secret)
            ok = r.ok
            message = r.message
            if r.ok { input = "" }
            checking = false
        }
    }
}

/// Ô thêm thuật ngữ. Dùng ObservableObject thay cho @State (xem ghi chú ở Engine).
@MainActor
final class GlossaryForm: ObservableObject {
    @Published var term = ""
    @Published var translation = ""
    @Published var bulk = ""
    @Published var message = ""

    func addOne(to settings: AppSettings) {
        settings.addTerm(term, translation: translation)
        message = L("Đã thêm \"\(term.trimmingCharacters(in: .whitespaces))\".", "Added \"\(term.trimmingCharacters(in: .whitespaces))\".")
        term = ""; translation = ""
    }

    func addBulk(to settings: AppSettings) {
        let n = settings.addTerms(fromLines: bulk)
        message = n == 0 ? L("Không có dòng hợp lệ.", "No valid lines.") : L("Đã thêm \(n) thuật ngữ.", "Added \(n) terms.")
        if n > 0 { bulk = "" }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, capture, display, window, dub, cast, screen, translate, smart, presets, shortcuts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("Ngôn ngữ & game", "Languages & game")
        case .capture: return L("Vùng", "Regions")
        case .display: return L("Phụ đề", "Subtitles")
        case .window: return L("Cửa sổ phụ đề", "Subtitle window")
        case .dub: return L("Giọng đọc", "Voice")
        case .cast: return L("Nhân vật", "Characters")
        case .screen: return L("Dịch màn hình", "Screen translation")
        case .translate: return L("Dịch vụ dịch", "Translation services")
        case .smart: return L("Văn phong & thuật ngữ", "Style & glossary")
        case .presets: return L("Hồ sơ game", "Game profiles")
        case .shortcuts: return L("Phím tắt & tay cầm", "Shortcuts & controller")
        case .about: return L("Chung", "General")
        }
    }

    var icon: String {
        switch self {
        case .general: return "globe"
        case .capture: return "viewfinder"
        case .display: return "captions.bubble"
        case .window: return "macwindow"
        case .dub: return "waveform"
        case .cast: return "person.2.fill"
        case .screen: return "text.viewfinder"
        case .translate: return "character.bubble"
        case .smart: return "sparkles"
        case .presets: return "square.stack.3d.up"
        case .shortcuts: return "command"
        case .about: return "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .blue
        case .capture: return .green
        case .display: return .teal
        case .window: return .cyan
        case .dub: return .pink
        case .cast: return .red
        case .screen: return .mint
        case .translate: return .orange
        case .smart: return .purple
        case .presets: return .indigo
        case .shortcuts: return .gray
        case .about: return .gray
        }
    }

    /// Trang Dàn diễn viên chỉ hiện khi đang dùng Dub (giọng theo nhân vật), để Voice-over không bị rối.
    static func groups(dub: Bool) -> [(title: String, pages: [SettingsPage])] {
        groups.map { g in (g.title, g.pages.filter { dub || $0 != .cast }) }
    }

    // Tính lại mỗi lần gọi (không phải static let) để tiêu đề nhóm đổi theo ngôn ngữ giao diện.
    static var groups: [(title: String, pages: [SettingsPage])] { [
        (L("Bắt đầu nhanh", "Quick start"), [.general, .capture]),
        (L("Tính năng", "Features"), [.display, .window, .dub, .cast, .screen]),
        (L("Bản dịch", "Translation"), [.translate, .smart]),
        (L("Ứng dụng", "App"), [.presets, .shortcuts, .about]),
    ] }
}

/// Gói Dịch máy Apple cho cặp ngôn ngữ đang dùng đã tải về máy chưa (chế độ dịch màn hình Tức thì cần nó).
@MainActor
final class ApplePackCheck: ObservableObject {
    enum State { case unknown, installed, downloadable, unsupported }
    @Published var state: State = .unknown
    @Published var request: TranslationSession.Configuration?

    func check(source: String, target: String) async {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: state = .installed
        case .supported: state = .downloadable
        default: state = .unsupported
        }
    }

    /// Hỏi macOS tải gói: hệ thống hiện hộp thoại xin phép tải.
    func download(source: String, target: String) {
        request = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
    }
}

@MainActor
final class SettingsNav: ObservableObject {
    @Published var page: SettingsPage? = .general
    @Published var presetDetail: UUID?     // đang xem trang chi tiết của preset nào (nil = danh sách)
    @Published var presetName = ""
    @Published var presetMessage = ""
}

/// Hàng có thanh trượt: mọi thanh trượt cùng một độ dài, số liệu cùng một cột, để các trang trông đều nhau.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                // Làm tròn theo bước trong binding thay vì Slider(step:), để macOS không vẽ hàng chấm vạch chia rối mắt.
                Slider(value: Binding(get: { value }, set: { v in value = step.map { (v / $0).rounded() * $0 } ?? v }), in: range)
                    .frame(width: 240)
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// Dòng ghi chú nhỏ dưới một cài đặt.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hub: TranslationHub
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) private var openWindow
    @StateObject private var nav = SettingsNav()
    @StateObject private var applePack = ApplePackCheck()
    @ObservedObject private var subtitleWindow = SubtitleWindowState.shared
    @StateObject private var geminiForm = KeyForm(provider: .gemini)
    @StateObject private var groqForm = KeyForm(provider: .groq)
    @StateObject private var cerebrasForm = KeyForm(provider: .cerebras)
    @StateObject private var mistralForm = KeyForm(provider: .mistral)
    @StateObject private var openRouterForm = KeyForm(provider: .openRouter)
    @StateObject private var customForm = KeyForm(provider: .custom)
    @StateObject private var glossaryForm = GlossaryForm()
    @ObservedObject private var hotkeys = HotkeyRecording.shared

    var body: some View {
        NavigationSplitView {
            // Bấm một mục ở thanh bên thì về trang đó (đóng trang chi tiết preset nếu đang mở).
            List(selection: Binding(get: { nav.page }, set: { p in
                guard p != nav.page else { return }
                nav.page = p
                nav.presetDetail = nil
            })) {
                ForEach(SettingsPage.groups(dub: settings.dubCharacters), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.pages) { page in
                            Label {
                                Text(page.title)
                            } icon: {
                                // Thu biểu tượng vừa khít ô vuông: biểu tượng rộng (sóng âm, hai người) không tràn ra ngoài.
                                Image(systemName: page.icon)
                                    .resizable().scaledToFit()
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .frame(width: 12, height: 12)
                                    .frame(width: 20, height: 20)
                                    .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .tag(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let page = nav.page ?? .general
            detail(page)
                .formStyle(.grouped)
                .navigationTitle(page.title)
                .id(page)
                .transition(.opacity)
        }
        .animation(.smooth(duration: 0.2), value: nav.page)
        .animation(.smooth(duration: 0.25), value: nav.presetDetail)
        .frame(minWidth: 820, idealWidth: 860, minHeight: 600, idealHeight: 680)
        .onAppear { takeRequestedPage() }
        .onChange(of: engine.requestedSettingsPage) { _, _ in takeRequestedPage() }
        .onChange(of: engine.requestedPresetDetail) { _, _ in takeRequestedPage() }
        .onChange(of: settings.dubCharacters) { _, dub in
            if !dub, nav.page == .cast { nav.page = .dub }   // tắt Dub khi đang xem Dàn diễn viên: về trang Giọng đọc
        }
        .onDisappear { engine.endDemo() }
    }

    private func takeRequestedPage() {
        if let p = engine.requestedSettingsPage {
            nav.page = (p == .cast && !settings.dubCharacters) ? .dub : p
            nav.presetDetail = nil
            engine.requestedSettingsPage = nil
        }
        if let id = engine.requestedPresetDetail {
            nav.page = .presets
            nav.presetDetail = id
            engine.requestedPresetDetail = nil
        }
    }

    @ViewBuilder
    private func detail(_ page: SettingsPage) -> some View {
        switch page {
        case .presets:
            if let id = nav.presetDetail {
                PresetDetailView(id: id, onBack: { nav.presetDetail = nil })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                presetsPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        case .general: generalPage
        case .window: windowPage
        case .shortcuts: shortcutsPage
        case .about: aboutPage
        case .translate: translatePage
        case .smart: smartPage
        case .display: displayPage
        case .capture: capturePage
        case .screen: screenPage
        case .dub: DubSettingsPage()
        case .cast: CastSettingsPage()
        }
    }

    // MARK: Preset

    private var presetsPage: some View {
        Form {
            Section {
                HStack {
                    TextField(L("Tên hồ sơ", "Profile name"), text: Binding(get: { nav.presetName }, set: { nav.presetName = $0 }),
                              prompt: Text(settings.gameAppName.map { L("\($0) – mới", "\($0) – new") } ?? L("Tên game", "Game name")))
                        .labelsHidden()
                    Button(L("Tạo hồ sơ mới", "Create profile")) {
                        let p = engine.createProfile(named: nav.presetName)
                        nav.presetName = ""
                        nav.presetMessage = L("Đã tạo và chuyển sang \"\(p.name)\".", "Created and switched to \"\(p.name)\".")
                    }
                    .buttonStyle(.glassProminent).tint(Theme.accent)
                }
                Note(L("Mỗi game một hồ sơ: các vùng, ngôn ngữ, phụ đề, giọng đọc, dịch vụ dịch, cùng trí nhớ game (ngữ cảnh hội thoại, dàn diễn viên, thuật ngữ, bộ nhớ dịch). Mọi thay đổi tự lưu vào hồ sơ đang dùng. Hồ sơ mới lấy cài đặt hiện tại với trí nhớ trống; cùng game thì dùng Nhân bản để giữ trí nhớ.", "One profile per game: regions, languages, subtitles, voice, translation services, plus game memory (dialogue context, cast, glossary, translation memory). Every change is saved to the active profile automatically. A new profile starts from the current settings with empty memory; for the same game, use Duplicate to keep the memory."))
                Toggle(L("Tự chuyển hồ sơ theo game đang mở", "Switch profiles automatically for the game in front"), isOn: $settings.autoSwitchProfile)
                Note(L("OverSub dùng được với mọi game đang hiện trên màn hình Mac. Đưa một game ra phía trước thì OverSub chuyển sang hồ sơ của game đó (nhận theo app đang hiện game). Chơi máy console qua app xem capture card (như OBS, VisionRelay) thì mọi game đều hiện qua cùng một app, OverSub không phân biệt được từng game: hãy chọn hồ sơ bằng tay.", "OverSub works with any game shown on your Mac's screen. Bring a game to the front and OverSub switches to its profile (matched by the app showing the game). If you play a console through a capture-card viewer (such as OBS or VisionRelay), every game appears in the same app and OverSub can't tell them apart: pick the profile yourself."))
            } header: { Text(L("Hồ sơ mới", "New profile")) }

            Section {
                ForEach(settings.presets) { p in presetRow(p) }
            } header: {
                HStack {
                    Text(L("Hồ sơ của bạn (\(settings.presets.count))", "Your profiles (\(settings.presets.count))"))
                    Spacer()
                    Button(L("Nhập…", "Import…")) { if let m = PresetIO.importFile(settings) { nav.presetMessage = m } }
                    Button(L("Xuất tất cả…", "Export all…")) { if let m = PresetIO.export(settings) { nav.presetMessage = m } }
                }
                .buttonStyle(.borderless)
            } footer: {
                if !nav.presetMessage.isEmpty { Text(nav.presetMessage) }
            }
        }
    }

    private func presetRow(_ p: Preset) -> some View {
        let active = p.id == settings.activePresetID
        return HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.green : Color.secondary.opacity(0.5))
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(.body.weight(.semibold))
                    if active {
                        Text(L("Đang dùng", "In use")).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.green.opacity(0.2), in: Capsule())
                    }
                }
                Text(presetSummary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !active { Button(L("Dùng", "Use")) { engine.applyPreset(p) } }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { nav.presetDetail = p.id }
        .help(L("Xem chi tiết và chỉnh nhanh hồ sơ này", "View details and quick settings for this profile"))
    }

    private func presetSummary(_ p: Preset) -> String {
        let s = p.snapshot
        var parts: [String] = []
        if let g = s.gameAppName { parts.append(g) }
        if let t = s.targetLanguage { parts.append("→ " + TargetLanguage.find(t).displayName) }
        if let g = s.genre.flatMap(GameGenre.init(rawValue:)) { parts.append(g.title.components(separatedBy: " (").first ?? "") }
        if let m = CaptureMode.from(s.captureMode) { parts.append(m.title) }
        if let m = s.outputMode.flatMap(OutputMode.init(rawValue:)) {
            parts.append(m.speaks ? ((s.dubCharacters ?? false) ? "Dub" : "Voice-over") : L("không đọc", "no voice"))
        }
        if let n = s.cast?.filter({ !$0.isNarrator }).count, n > 0 { parts.append(L("\(n) nhân vật", "\(n) characters")) }
        let ctx = ContextStore.count(for: p.id)
        if ctx > 0 { parts.append(L("nhớ \(ctx) câu", "\(ctx) lines of context")) }
        let mem = engine.memory.count(for: p.id)
        if mem > 0 { parts.append(L("\(mem) câu đã dịch", "\(mem) translated lines")) }
        if let n = s.glossary?.count, n > 0 { parts.append(L("\(n) thuật ngữ", "\(n) terms")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Phím tắt & thanh menu

    private var shortcutsPage: some View {
        Form {
            Section {
                Toggle(L("Bật phím tắt toàn cục", "Enable global shortcuts"), isOn: $settings.globalHotkeys)
                ForEach([HotkeyCenter.Action.toggleOverlay, .toggleDub, .replayLast, .toggleRunning, .selectRegion, .screenTranslate, .quickTranslate, .history], id: \.rawValue) { a in
                    LabeledContent(a.title) { HotkeyField(action: a) }
                        .opacity(settings.globalHotkeys ? 1 : 0.4)
                        .disabled(!settings.globalHotkeys)
                }
                if !hotkeys.message.isEmpty { Note(hotkeys.message) }
                Note(L("Bấm vào ô phím tắt rồi gõ tổ hợp mới để đổi; Esc để thôi.", "Click a shortcut, then press the new combination to change it; Esc cancels."))
                Note(L("Dùng được ngay cả khi game đang toàn màn hình, không cần cấp quyền Trợ năng. Trong cửa sổ OverSub còn có ⌘R bắt đầu/dừng, ⇧⌘H phụ đề, ⇧⌘D giọng đọc, ⇧⌘T dịch màn hình, ⇧⌘R đọc lại, ⌘K chọn vùng, ⌘J cửa sổ phụ đề, ⌘L lịch sử.", "Works even when the game is full screen, with no Accessibility permission needed. In the OverSub window you can also use ⌘R to start/stop, ⇧⌘H subtitles, ⇧⌘D voice, ⇧⌘T screen translation, ⇧⌘R replay, ⌘K select region, ⌘J subtitle window, ⌘L history."))
            } header: { Text(L("Phím tắt trong game", "In-game shortcuts")) }
            Section {
                Toggle(L("Điều khiển bằng tay cầm game", "Control with a game controller"), isOn: $settings.gamepadControls)
                ForEach(GamepadControl.combos, id: \.buttons) { c in
                    LabeledContent(c.action) {
                        Text(c.buttons)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .opacity(settings.gamepadControls ? 1 : 0.4)
                }
                Note(L("Giữ nút nhỏ View/Share (bên trái tay cầm) rồi bấm thêm nút, dùng được cả khi game đang ở phía trước. Tay cầm Xbox, PlayStation, Switch Pro kết nối qua Bluetooth hoặc cáp đều được.", "Hold the small View/Share button (on the left of the controller), then press another button. Works even while the game is in front. Xbox, PlayStation and Switch Pro controllers all work over Bluetooth or cable."))
            } header: { Text(L("Tay cầm", "Controller")) }
        }
    }

    // MARK: Giới thiệu

    private var aboutPage: some View {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"
        return Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OverSub").font(.title.weight(.bold))
                        Text(L("Phụ đề, giọng đọc và dịch màn hình cho mọi game trên Mac", "Subtitles, voice and screen translation for any game on Mac")).foregroundStyle(.secondary)
                        Text(L("Phiên bản \(version) (\(build))", "Version \(version) (\(build))")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }
            UpdateSection()
            Section {
                Picker(L("Sáng / tối", "Light / dark"), selection: $settings.appearance) {
                    Text(L("Theo hệ thống", "System")).tag("system")
                    Text(L("Sáng", "Light")).tag("light")
                    Text(L("Tối", "Dark")).tag("dark")
                }
                .pickerStyle(.segmented)
                Picker(L("Ngôn ngữ", "Language"), selection: $settings.appLanguage) {
                    Text(L("Tự động theo máy", "Match system")).tag("auto")
                    Text("Tiếng Việt").tag("vi")
                    Text("English").tag("en")
                }
                Note(L("Cửa sổ phụ đề và chữ dịch đè lên game luôn nền tối cho dễ đọc. Đổi ngôn ngữ thì thanh menu và menu của app đổi theo sau khi mở lại OverSub.", "The subtitle window and in-game translations always use a dark background for readability. After changing the language, the menu bar and app menus update once you reopen OverSub."))
            } header: { Text(L("Giao diện", "Appearance")) }
            Section {
                LabeledContent {
                    Button(L("Ủng hộ OverSub…", "Support OverSub…")) { openWindow(id: "donate") }
                } label: {
                    Label {
                        Text(L("OverSub miễn phí. Thấy hữu ích thì mời mình một ly cà phê nhé.", "OverSub is free. If you find it useful, buy me a coffee."))
                    } icon: {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                    }
                }
            } header: { Text(L("Ủng hộ", "Support the developer")) }
            Section {
                Toggle(L("Hiện biểu tượng trên thanh menu", "Show icon in the menu bar"), isOn: $settings.menuBarIcon)
                Note(L("Điều khiển OverSub mà không cần mở cửa sổ: bật/tắt ba tính năng, bắt đầu, chọn vùng, đổi hồ sơ game, đổi ngôn ngữ dịch.", "Control OverSub without opening its window: toggle the three features, start, select a region, switch game profile, change the target language."))
            } header: { Text(L("Thanh menu", "Menu bar")) }
            Section {
                LabeledContent(L("Hướng dẫn lần đầu", "First-run guide")) {
                    Button(L("Xem lại", "Show again")) {
                        settings.onboardingDone = false
                        openWindow(id: "main")
                    }
                }
                LabeledContent(L("Nhật ký chẩn đoán", "Diagnostic log")) {
                    Button(L("Mở trong Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url]) }
                }
                LabeledContent(L("Thư mục dữ liệu (key API)", "Data folder (API keys)")) {
                    Button(L("Mở trong Finder", "Open in Finder")) {
                        let dir = AppPaths.support
                        NSWorkspace.shared.open(dir)
                    }
                }
                Note(L("Nhật ký ghi chữ đọc được trong các vùng bạn chọn và quyết định của app, không ghi key, tự xoá khi quá 2 MB. Gửi kèm khi báo lỗi để dễ tìm nguyên nhân.", "The log records text read in the regions you select and the app's decisions. It never records API keys and clears itself past 2 MB. Attach it to bug reports to help find the cause."))
            } header: { Text(L("Hỗ trợ", "Support")) }
            Section {
                Note(L("Ảnh màn hình không rời khỏi máy: chữ được nhận ngay trên máy bằng Vision. Khi bạn thêm key Gemini hoặc Groq, chữ trong các vùng bạn chọn được gửi tới dịch vụ đó để dịch, kèm vài câu trước làm ngữ cảnh, tên nhân vật và thuật ngữ của bạn. Dịch máy Apple và Apple Intelligence chạy hoàn toàn trên máy.", "Screenshots never leave your Mac: text is recognized on device with Vision. When you add a Gemini or Groq API key, text in the regions you select is sent to that service for translation, along with a few previous lines as context, character names and your glossary. Apple Translation and Apple Intelligence run entirely on device."))
            } header: { Text(L("Quyền riêng tư", "Privacy")) }
        }
    }

    // MARK: Dịch

    private var translatePage: some View {
        Form {
            Section {
                Toggle(L("Hiện tạm bản Dịch máy Apple khi AI chưa kịp", "Show Apple Translation while the AI catches up"), isOn: $settings.quickAppleTranslation)
                Note(L("AI chưa trả lời sau 0,25 giây thì phụ đề hiện tạm bản dịch máy của Apple (trên máy, gần như tức thì), có bản AI thì thay. Giọng đọc luôn chờ bản AI. Gemini và Groq trả bản dịch theo luồng: chữ hiện dần và câu đầu được đọc ngay khi dịch xong, không chờ cả đoạn.", "If the AI hasn't answered after 0.25 seconds, subtitles show Apple's machine translation (on device, almost instant) and switch to the AI version when it arrives. Voice always waits for the AI version. Gemini and Groq stream their translations: text appears as it comes in and the first sentence is spoken as soon as it's translated, without waiting for the whole passage."))
                LabeledContent(L("Bộ nhớ dịch của hồ sơ này", "Translation memory for this profile")) {
                    Text(L("\(engine.memory.count) câu", "\(engine.memory.count) lines")).foregroundStyle(.secondary)
                }
                Note(L("Câu đã dịch được nhớ theo hồ sơ game; gặp lại (NPC nói lặp, xem lại hội thoại) thì dùng ngay, không tốn lượt. Xoá ở trang chi tiết hồ sơ.", "Translated lines are remembered per game profile; when they come up again (repeated NPC lines, rewatched dialogue) they're reused instantly at no cost to your quota. Clear it on the profile's detail page."))
            } header: { Text(L("Tốc độ", "Speed")) }

            Section {
                Picker(L("Ưu tiên", "Priority"), selection: $settings.enginePreference) {
                    ForEach(EnginePreference.allCases) { Text($0.title).tag($0) }
                }
                Note(settings.enginePreference.detail)
                if settings.enginePreference == .custom {
                    // Chỉ hiện dịch vụ đang bật và đã có key; dịch vụ mới thêm nằm cuối, muốn ưu tiên thì tự kéo lên.
                    let active = hub.currentOrder()
                    ForEach(Array(active.enumerated()), id: \.element) { i, e in
                        HStack {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(e.title)
                            Spacer()
                            Button { settings.swapCustom(e, with: active[i - 1]) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { settings.swapCustom(e, with: active[i + 1]) } label: { Image(systemName: "chevron.down") }
                                .disabled(i == active.count - 1)
                        }
                        .buttonStyle(.borderless)
                    }
                    Note(L("Dịch vụ mới bật hoặc mới thêm key sẽ nằm cuối danh sách.", "A service you just turned on or added a key for goes to the end of the list."))
                } else {
                    LabeledContent(L("Thứ tự thử", "Order tried")) {
                        Text(hub.currentOrder().map(\.title).joined(separator: " → ")).foregroundStyle(.secondary)
                    }
                }
            } header: { Text(L("Thứ tự ưu tiên", "Priority order")) }

            Section {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 12) {
                        // Dịch vụ chưa có key thì chưa hiện ở đây; thêm key ở các mục bên dưới.
                        ForEach(EngineKind.allCases.filter { !$0.needsKey || !hub.keys(for: $0).isEmpty }) { e in engineRow(e, now: ctx.date) }
                    }
                }
                LabeledContent(L("Tốc độ từng dịch vụ", "Speed of each service")) {
                    Button(hub.benchmarking ? L("Đang đo…", "Measuring…") : L("Đo lại", "Measure again")) { Task { await hub.benchmark() } }
                        .disabled(hub.benchmarking)
                }
                Note(L("Số ms là trung vị của 20 lần dịch gần nhất, có cộng phạt khi dịch vụ hay lỗi; app dùng số này để tự sắp thứ tự ở chế độ Cân bằng và Ưu tiên tốc độ. Số đo được giữ qua các lần mở app. Đo lại tốn hai lượt dịch của mỗi dịch vụ.", "The ms figure is the median of the last 20 translations, with a penalty when a service fails often; the app uses it to order services in Balanced and Prefer speed. Measurements are kept between launches. Measuring again uses two requests per service."))
            } header: { Text(L("Trạng thái dịch vụ", "Service status")) }

            Section {
                capabilityRow(L("Dịch vụ AI qua mạng (Gemini, Groq, Cerebras, Mistral, OpenRouter, tự thêm)", "Online AI services (Gemini, Groq, Cerebras, Mistral, OpenRouter, custom)"), L("Hỗ trợ đầy đủ: lọc nội dung, xưng hô, văn phong và tên riêng. Khuyên dùng.", "Full support: content filtering, forms of address, style and proper names. Recommended."), .green)
                capabilityRow("Apple Intelligence", L("Lọc bằng quy tắc và giữ tên riêng. Không dùng AI để lọc vì dễ bỏ sót lời thoại.", "Rule-based filtering and proper names kept. AI isn't used for filtering because it tends to drop dialogue."), .orange)
                capabilityRow(L("Dịch máy Apple", "Apple Translation"), L("Nhanh nhất, chạy trên máy. Lọc bằng quy tắc và dùng danh sách thuật ngữ; không giữ được xưng hô.", "Fastest, runs on device. Rule-based filtering and your glossary; can't keep forms of address."), .secondary)
            } header: { Text(L("Khả năng của từng dịch vụ", "What each service can do")) }

            keySection("Gemini", engine: .gemini, form: geminiForm,
                       hint: L("Dịch hay nhất trong nhóm miễn phí. Hạn mức tính theo dự án Google Cloud chứ không theo key: hai key cùng một dự án dùng chung hạn mức, và Google có thể khoá các dự án lập ra chỉ để né hạn mức. Muốn có dự phòng thì thêm key của dịch vụ khác bên dưới.", "The best translations among the free options. Quota is per Google Cloud project, not per key: two keys from one project share the same quota, and Google may restrict projects created just to get around limits. For a backup, add a key from another service below."))
            keySection("Groq", engine: .groq, form: groqForm,
                       hint: L("Rất nhanh (khoảng 0,3 đến 0,5 giây). Miễn phí khoảng 1.000 lượt mỗi ngày cho mỗi model.", "Very fast (about 0.3 to 0.5 seconds). Free for roughly 1,000 requests per day per model."))
            keySection("Cerebras", engine: .cerebras, form: cerebrasForm,
                       hint: L("Nhanh ngang Groq. Miễn phí khoảng 1 triệu token mỗi ngày, đủ cho vài nghìn câu thoại.", "As fast as Groq. Free for about 1 million tokens per day, enough for a few thousand lines."))
            keySection("Mistral", engine: .mistral, form: mistralForm,
                       hint: L("Gói miễn phí rộng nhất (khoảng 1 tỉ token mỗi tháng) nhưng chỉ một lượt mỗi giây. Hợp làm dự phòng khi Gemini và Groq hết lượt.", "The most generous free plan (about 1 billion tokens per month) but only one request per second. A good backup when Gemini and Groq run out."))
            keySection("OpenRouter", engine: .openRouter, form: openRouterForm,
                       hint: L("Một key dùng được nhiều model. Model miễn phí (tên có đuôi :free) giới hạn 50 lượt mỗi ngày, lên 1.000 lượt khi tài khoản đã nạp từ 10 USD. Muốn dùng model trả phí thì nhập tên model ở phần Nâng cao.", "One key for many models. Free models (names ending in :free) are limited to 50 requests per day, or 1,000 once the account has bought at least $10 of credits. To use a paid model, enter its name under Advanced."))
            customSection

            Section {
                Note(L("Chỉ thêm key chạy được; lúc thêm, app gửi ba câu thử để đo tốc độ. Hết hạn mức thì app tự chuyển sang key hoặc dịch vụ kế tiếp. Khi dùng dịch vụ qua mạng, chữ trong các vùng bạn chọn (kèm vài câu trước làm ngữ cảnh và tên nhân vật) được gửi tới dịch vụ đó để dịch. Key lưu trong một file chỉ tài khoản của bạn đọc được.", "Only working keys are added; when you add one, the app sends three test lines to measure speed. When a quota runs out, the app moves on to the next key or service. When you use an online service, text in the regions you select (plus a few previous lines as context and character names) is sent to that service for translation. Keys are stored in a file only your account can read."))
            }
            Section {
                DisclosureGroup(L("Nhật ký chuyển dịch vụ (\(hub.log.count))", "Service switch log (\(hub.log.count))")) {
                    if hub.log.isEmpty {
                        Text(L("Chưa có lần chuyển nào.", "No switches yet.")).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(hub.log) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Text(e.time, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.text).font(.caption)
                        }
                    }
                    if !hub.log.isEmpty { Button(L("Xoá nhật ký", "Clear log")) { hub.clearLog() } }
                }
                DisclosureGroup(L("Nâng cao: tên model", "Advanced: model names")) {
                    TextField(L("Model Gemini", "Gemini model"), text: $settings.geminiModel)
                    TextField(L("Model Groq", "Groq model"), text: $settings.groqModel)
                    ForEach([EngineKind.cerebras, .mistral, .openRouter]) { e in
                        TextField(L("Model \(e.title)", "\(e.title) model"), text: modelBinding(e))
                    }
                    Note(L("Model không còn dùng được với tài khoản thì app tự chọn model khác khi thêm key hoặc khi dịch gặp lỗi.", "If a model is no longer available on your account, the app picks another one when you add a key or when a translation fails."))
                }
            }
        }
    }

    private func engineRow(_ e: EngineKind, now: Date) -> some View {
        let info = hub.info(e, now: now)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(info.health)).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).font(.body.weight(.medium))
                    Text(e.detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(info.text).font(.caption).foregroundStyle(color(info.health))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !settings.disabledEngines.contains(e) },
                                     set: { settings.setEngine(e, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func color(_ h: TranslationHub.Health) -> Color {
        switch h {
        case .good: return .green
        case .degraded: return .orange
        case .down: return .red
        case .unknown, .off: return .secondary
        }
    }

    private func modelBinding(_ e: EngineKind) -> Binding<String> {
        Binding(get: { settings.model(for: e) }, set: { settings.setModel($0.trimmingCharacters(in: .whitespaces), for: e) })
    }

    /// Dịch vụ trả phí bất kỳ dùng kiểu API của OpenAI: người dùng nhập địa chỉ, model và key.
    private var customSection: some View {
        Section {
            LabeledContent(L("Chọn nhanh", "Quick pick")) {
                Menu(L("Điền sẵn địa chỉ…", "Fill in an address…")) {
                    ForEach([("OpenAI", "https://api.openai.com/v1", "gpt-5-mini"), ("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
                             ("xAI (Grok)", "https://api.x.ai/v1", "grok-4-fast-non-reasoning"), ("Together AI", "https://api.together.xyz/v1", ""),
                             ("Fireworks", "https://api.fireworks.ai/inference/v1", "")], id: \.0) { item in
                        Button(item.0) {
                            settings.customEngineName = item.0
                            settings.customEngineURL = item.1
                            settings.setModel(item.2, for: .custom)
                        }
                    }
                }
                .fixedSize()
            }
            TextField(L("Tên hiển thị", "Display name"), text: $settings.customEngineName, prompt: Text("OpenAI"))
            TextField(L("Địa chỉ API", "API address"), text: $settings.customEngineURL, prompt: Text("https://api.openai.com/v1"))
            TextField(L("Tên model", "Model name"), text: modelBinding(.custom), prompt: Text(L("Để trống thì app tự chọn khi thêm key", "Leave empty and the app picks one when you add a key")))
            keyRows(L("dịch vụ này", "this service"), engine: .custom, form: customForm)
        } header: {
            Text(L("Dịch vụ tự thêm (\(hub.keys(for: .custom).count))", "Custom service (\(hub.keys(for: .custom).count))"))
        } footer: {
            Text(L("Dùng cho dịch vụ trả phí có API kiểu OpenAI (chat/completions). Phí do nhà cung cấp tính theo lượng chữ; một câu thoại tốn khoảng 300 đến 600 token kèm ngữ cảnh. Tên model có thể đã đổi, xem trang của nhà cung cấp nếu app báo model không dùng được.", "For paid services with an OpenAI-style API (chat/completions). The provider bills by text volume; one line of dialogue uses roughly 300 to 600 tokens including context. Model names change, so check the provider's site if the app reports a model as unavailable."))
        }
    }

    private func keySection(_ name: String, engine e: EngineKind, form: KeyForm, hint: String) -> some View {
        Section {
            keyRows(name, engine: e, form: form)
        } header: {
            HStack {
                Text(L("Key \(name) (\(hub.keys(for: e).count))", "\(name) API keys (\(hub.keys(for: e).count))"))
                Spacer()
                if let url = URL(string: e.keyLink) { Link(L("Lấy key miễn phí", "Get a free API key"), destination: url) }
            }
        } footer: {
            Text(hint)
        }
    }

    @ViewBuilder
    private func keyRows(_ name: String, engine e: EngineKind, form: KeyForm) -> some View {
        Group {
            HStack {
                TextField(L("Key \(name)", "\(name) API key"), text: Binding(get: { form.input }, set: { form.input = $0 }), prompt: Text(L("Dán key \(name)", "Paste \(name) API key")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button(form.checking ? L("Đang kiểm tra…", "Checking…") : L("Kiểm tra & thêm", "Check & add")) { form.submit(hub: hub) }
                    .disabled(form.checking || form.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !form.message.isEmpty && !form.checking {
                Label(form.message, systemImage: form.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(form.ok ? Color.green : Color.red)
                    .transition(.opacity)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let list = hub.keys(for: e)
                VStack(alignment: .leading, spacing: 8) {
                    if list.isEmpty { Text(L("Chưa có key nào.", "No API keys yet.")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(list) { k in
                        let st = hub.keyStatus(k, now: ctx.date)
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(st.ok ? Color.green : Color.orange).frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(k.masked).font(.system(size: 12, design: .monospaced))
                                Text(st.text).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { hub.removeKey(k.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    // MARK: Chất lượng dịch

    private var smartPage: some View {
        Form {
            Section {
                Toggle(L("Chỉ dịch lời thoại", "Translate dialogue only"), isOn: $settings.smartSubtitleOnly)
                Note(L("Tự bỏ qua chữ giao diện như menu, nút bấm, chỉ số, logo và dòng bản quyền. Gemini và Groq nhận diện thêm những trường hợp khó; câu bạn đã đánh dấu bỏ qua thì luôn được bỏ qua.", "Skips interface text such as menus, buttons, stats, logos and copyright lines. Gemini and Groq also catch the harder cases; lines you've marked to ignore are always skipped."))
            } header: { Text(L("Lọc nội dung", "Content filtering")) }

            Section {
                LabeledContent(L("Thể loại game", "Game genre")) {
                    HStack {
                        Text(settings.genre.title.components(separatedBy: " (").first ?? "").foregroundStyle(.secondary)
                        Button(L("Đổi ở Ngôn ngữ & game", "Change in Languages & game")) { nav.page = .general }.buttonStyle(.link)
                    }
                }
                Toggle(L("Giữ xưng hô nhất quán", "Keep forms of address consistent"), isOn: $settings.smartPronouns)
                Note(L("Dựa vào tên người nói và 10 câu gần nhất để giữ cách xưng hô, giới tính và giọng văn của từng nhân vật. Ngữ cảnh được lưu theo hồ sơ game (tối đa \(ContextStore.limit) câu) và tiếp tục khi bạn quay lại.", "Uses the speaker's name and the last 10 lines to keep each character's forms of address, gender and tone consistent. Context is saved per game profile (up to \(ContextStore.limit) lines) and picks up where you left off."))
                Toggle(L("Tự quên ngữ cảnh khi im lặng lâu", "Forget context after a long silence"), isOn: $settings.contextAutoForget)
                if settings.contextAutoForget {
                    SliderRow(title: L("Quên sau", "Forget after"), value: $settings.contextResetSeconds, range: 15...300, step: 5, format: L("%.0f giây", "%.0f sec"))
                    Note(L("Phù hợp với game có nhiều cuộc hội thoại rời rạc.", "Good for games with many separate conversations."))
                }
                LabeledContent(L("Ngữ cảnh hiện tại", "Current context")) {
                    HStack {
                        Text(L("\(engine.contextCount)/\(ContextStore.limit) câu", "\(engine.contextCount)/\(ContextStore.limit) lines")).foregroundStyle(.secondary)
                        Button(L("Xoá ngữ cảnh", "Clear context")) { engine.clearContext() }.disabled(engine.contextCount == 0)
                    }
                }
            } header: { Text(L("Văn phong & xưng hô", "Style & forms of address")) }

            Section {
                Toggle(L("Giữ nguyên tên riêng", "Keep proper names as is"), isOn: $settings.smartNames)
                Note(L("Tên nhân vật, địa danh, quái vật và chiêu thức được giữ như bản gốc. Thêm vào danh sách bên dưới để giữ chắc chắn, hoặc đặt một cách dịch cố định.", "Character, place, monster and skill names are kept as in the original. Add them to the list below to make sure, or set a fixed translation."))
                HStack {
                    TextField(L("Thuật ngữ", "Glossary term"), text: Binding(get: { glossaryForm.term }, set: { glossaryForm.term = $0 }), prompt: Text(L("Tên hoặc thuật ngữ", "Name or term")))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    TextField(L("Bản dịch", "Translation"), text: Binding(get: { glossaryForm.translation }, set: { glossaryForm.translation = $0 }), prompt: Text(L("Luôn dịch thành (trống = giữ nguyên)", "Always translate as (empty = keep as is)")))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    Button(L("Thêm", "Add")) { glossaryForm.addOne(to: settings) }
                        .disabled(glossaryForm.term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                DisclosureGroup(L("Thêm nhiều dòng một lúc", "Add several lines at once")) {
                    Note(L("Mỗi dòng một mục: \"Tên\" để giữ nguyên, hoặc \"Tên = Bản dịch\".", "One entry per line: \"Name\" to keep it as is, or \"Name = Translation\"."))
                    TextEditor(text: Binding(get: { glossaryForm.bulk }, set: { glossaryForm.bulk = $0 }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Button(L("Thêm các dòng trên", "Add these lines")) { glossaryForm.addBulk(to: settings) }
                        .disabled(glossaryForm.bulk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !glossaryForm.message.isEmpty { Note(glossaryForm.message) }
                ForEach(settings.glossary) { entry in
                    HStack {
                        Text(entry.term).font(.body.weight(.medium)).frame(minWidth: 140, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        TextField(L("Bản dịch", "Translation"), text: Binding(
                            get: { settings.glossary.first { $0.id == entry.id }?.translation ?? "" },
                            set: { v in
                                if let i = settings.glossary.firstIndex(where: { $0.id == entry.id }) {
                                    settings.glossary[i].translation = v.isEmpty ? nil : v
                                }
                            }))
                            .textFieldStyle(.plain).labelsHidden()
                        Button(role: .destructive) { settings.glossary.removeAll { $0.id == entry.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: { Text(settings.glossary.isEmpty ? L("Tên riêng & thuật ngữ", "Proper names & glossary") : L("Tên riêng & thuật ngữ · \(settings.glossary.count)", "Proper names & glossary · \(settings.glossary.count)")) } footer: {
                Text(L("Khi đang chơi, bấm \"Giữ nguyên tên riêng…\" ở cửa sổ chính để chọn nhanh tên trong câu đang hiện.", "While playing, click \"Keep proper names…\" in the main window to quickly pick names from the current line."))
            }

            Section {
                if settings.ignoreList.isEmpty {
                    Note(L("Chưa có câu nào. Bấm \"Bỏ qua câu này\" ở cửa sổ chính khi app dịch nhầm chữ không phải lời thoại.", "No lines yet. Click \"Ignore this line\" in the main window when the app translates text that isn't dialogue."))
                }
                ForEach(settings.ignoreList, id: \.self) { t in
                    HStack {
                        Text(t).lineLimit(2)
                        Spacer()
                        Button(role: .destructive) { settings.ignoreList.removeAll { $0 == t } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: { Text(settings.ignoreList.isEmpty ? L("Câu luôn bỏ qua", "Always-ignored lines") : L("Câu luôn bỏ qua · \(settings.ignoreList.count)", "Always-ignored lines · \(settings.ignoreList.count)")) }

        }
    }

    private func capabilityRow(_ name: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Note(text)
            }
        }
    }

    // MARK: Phụ đề & cửa sổ

    /// Các ô để người dùng tự mô tả bối cảnh và cách dịch cho thể loại Tuỳ chỉnh.
    @ViewBuilder
    private var customStyleEditor: some View {
        Note(L("Mô tả game để AI dịch theo ý bạn. Ô nào không cần thì để trống. Viết ngắn gọn: mỗi ô tối đa \(CustomStyle.fieldLimit) ký tự được gửi kèm mỗi câu dịch.", "Describe the game so the AI translates the way you want. Leave any box empty if you don't need it. Keep it short: up to \(CustomStyle.fieldLimit) characters per box are sent with every line."))
        LabeledContent(L("Bắt đầu từ thể loại có sẵn", "Start from a built-in genre")) {
            Menu(L("Điền sẵn…", "Fill in…")) {
                ForEach(GameGenre.allCases.filter { $0 != .custom && $0 != .auto }) { g in
                    Button(g.title.components(separatedBy: " (").first ?? g.title) {
                        settings.customStyle.tone = settings.target.isVietnamese ? g.styleGuide : g.englishHint
                    }
                }
            }
            .fixedSize()
        }
        styleField(L("Bối cảnh game", "Game and setting"), \.world,
                   L("Tên game, thế giới, thời đại. Vd: Zelda TOTK, vương quốc Hyrule giả tưởng", "Game title, world, era. E.g. Zelda TOTK, the fantasy kingdom of Hyrule"))
        styleField(L("Nhân vật & quan hệ", "Characters & relationships"), \.characters,
                   L("Vd: Link là nam chính, ít nói; Zelda là công chúa, bạn thân của Link", "E.g. Link is the quiet hero; Zelda is the princess and his close friend"))
        styleField(L("Xưng hô", "Forms of address"), \.address,
                   L("Vd: Link – Zelda xưng tớ – cậu; với vua thì thưa bệ hạ", "E.g. Link and Zelda speak informally; address the king as Your Majesty"))
        styleField(L("Giọng văn", "Tone"), \.tone,
                   L("Vd: nhẹ nhàng, hơi cổ, không dùng tiếng lóng", "E.g. gentle, slightly archaic, no slang"))
        Picker(L("Mức trang trọng", "Formality"), selection: $settings.customStyle.formality) {
            ForEach(CustomStyle.Formality.allCases) { Text($0.title).tag($0) }
        }
        Picker(L("Từ chửi thề", "Profanity"), selection: $settings.customStyle.profanity) {
            ForEach(CustomStyle.Profanity.allCases) { Text($0.title).tag($0) }
        }
        Toggle(L("Giữ kính ngữ (-san, -kun, senpai…)", "Keep honorifics (-san, -kun, senpai…)"), isOn: $settings.customStyle.keepHonorifics)
        styleField(L("Yêu cầu khác", "Other instructions"), \.extra,
                   L("Viết tự do cho AI. Vd: dịch tên chiêu thức sang Hán Việt; \"Rupee\" giữ nguyên", "Free-form instructions for the AI. E.g. keep \"Rupee\" as is"), lines: 3...6)
        DisclosureGroup(L("Xem hướng dẫn sẽ gửi cho AI", "Preview the guide sent to the AI")) {
            Text(settings.customStyle.guide(vietnamese: settings.target.isVietnamese) ?? L("Chưa điền gì: AI tự suy ra thể loại từ nội dung.", "Nothing filled in: the AI infers the genre from the content."))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Note(L("Hướng dẫn này lưu theo hồ sơ game và chỉ có tác dụng với dịch vụ AI qua mạng (Gemini, Groq…); Apple không nhận chỉ dẫn.", "This guide is saved per game profile and only affects online AI services (Gemini, Groq…); Apple's engines don't take instructions."))
    }

    private func styleField(_ title: String, _ key: WritableKeyPath<CustomStyle, String>, _ hint: String, lines: ClosedRange<Int> = 1...3) -> some View {
        TextField(title, text: Binding(get: { settings.customStyle[keyPath: key] }, set: { settings.customStyle[keyPath: key] = $0 }),
                  prompt: Text(hint), axis: .vertical)
            .lineLimit(lines)
    }

    /// Việc đầu tiên cần đặt: game dùng ngôn ngữ gì, dịch sang gì, thể loại nào.
    private var generalPage: some View {
        Form {
            Section {
                Picker(L("Ngôn ngữ trong game", "Game language"), selection: $settings.sourceLanguage) {
                    ForEach(SourceLanguage.all) { Text($0.displayName).tag($0.ocr) }
                }
                Picker(L("Dịch sang", "Translate to"), selection: $settings.targetLanguage) {
                    ForEach(TargetLanguage.all) { Text($0.displayName).tag($0.code) }
                }
                if !settings.target.isVietnamese {
                    Note(L("Xưng hô và văn phong theo thể loại được tinh chỉnh kỹ nhất cho tiếng Việt; các ngôn ngữ khác dùng bộ hướng dẫn chung.", "Forms of address and genre style are tuned most carefully for Vietnamese; other languages use a general guide."))
                }
                applePackNotice
            } header: { Text(L("Ngôn ngữ", "Languages")) }
            Section {
                Picker(L("Thể loại", "Genre"), selection: $settings.genre) {
                    ForEach(GameGenre.allCases) { Text($0.title).tag($0) }
                }
                if settings.genre == .custom {
                    customStyleEditor
                } else {
                    // Chỉ dẫn văn phong tiếng Việt (có ví dụ xưng hô) chỉ hiện khi giao diện tiếng Việt; giao diện tiếng Anh xem bản tiếng Anh.
                    Note(settings.target.isVietnamese && !Lang.isEnglish ? settings.genre.styleGuide : settings.genre.englishHint)
                }
            } header: { Text(L("Thể loại game", "Game genre")) }
            Section {
                LabeledContent(L("Game đang nhận", "Detected game")) {
                    Text(settings.gameAppName ?? L("Chưa nhận. Chọn vùng khi game đang mở.", "None yet. Select a region while the game is open.")).foregroundStyle(.secondary)
                }
                Toggle(L("Tạm ngưng khi game bị ẩn hoặc bị che", "Pause while the game is hidden or covered"), isOn: $settings.pauseWhenGameHidden)
                Note(L("Lúc chọn vùng, app nằm dưới vùng được nhận là game. Bấm sang app khác mà game vẫn hiện ở vùng phụ đề (vd. chơi console bằng tay cầm, gõ việc khác ở cửa sổ bên cạnh) thì vẫn dịch và đọc. Game bị thu nhỏ, chuyển màn hình làm việc, hay cửa sổ khác che vùng phụ đề thì tạm ngưng và ẩn bản dịch.", "When you select a region, the app beneath it is taken as the game. If you click another app but the game is still visible in the subtitle region (e.g. playing a console with a controller while typing in a window beside it), translation and voice keep going. If the game is minimized, you switch desktops, or another window covers the subtitle region, OverSub pauses and hides translations."))
            } header: { Text("Game") }
        }
        .task(id: settings.sourceLanguage + ">" + settings.targetLanguage) {
            await applePack.check(source: SourceLanguage.find(settings.sourceLanguage).code, target: settings.target.code)
        }
        .translationTask(applePack.request) { session in
            try? await session.prepareTranslation()   // macOS hỏi người dùng rồi tải gói
            await applePack.check(source: SourceLanguage.find(settings.sourceLanguage).code, target: settings.target.code)
        }
    }

    /// Nhắc tải gói Dịch máy Apple cho cặp ngôn ngữ đang chọn (dịch tức thì trên máy, không cần key).
    @ViewBuilder
    private var applePackNotice: some View {
        let src = SourceLanguage.find(settings.sourceLanguage), tgt = settings.target
        switch applePack.state {
        case .downloadable:
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Chưa có gói Dịch máy Apple \(src.displayName) → \(tgt.displayName). Tải gói để dịch tức thì ngay trên máy, không cần key và không cần mạng.", "The Apple Translation pack for \(src.displayName) → \(tgt.displayName) isn't installed. Download it to translate instantly on device, with no API key and no network."),
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Tải gói dịch", "Download language pack")) { applePack.download(source: src.code, target: tgt.code) }
            }
        case .unsupported:
            Label(L("Dịch máy Apple chưa hỗ trợ \(src.displayName) → \(tgt.displayName). Cần key Gemini hoặc Groq (miễn phí) ở trang Dịch vụ dịch.", "Apple Translation doesn't support \(src.displayName) → \(tgt.displayName) yet. You need a Gemini or Groq API key (free), added on the Translation services page."),
                  systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .installed:
            Label(L("Gói Dịch máy Apple \(src.displayName) → \(tgt.displayName) đã sẵn sàng.", "The Apple Translation pack for \(src.displayName) → \(tgt.displayName) is ready."), systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
    }

    /// Cửa sổ phụ đề: cửa sổ riêng chỉ có câu thoại.
    private var windowPage: some View {
        Form {
            Section {
                LabeledContent(L("Cửa sổ phụ đề", "Subtitle window")) {
                    Button(subtitleWindow.isOpen ? L("Đóng", "Close") : L("Mở   ⌘J", "Open   ⌘J")) { subtitleWindow.toggle() }
                }
                Note(L("Cửa sổ riêng chỉ có câu thoại: đặt ở màn hình thứ hai, hoặc thu còn một dòng để không che game. Rê chuột vào cửa sổ mới hiện nút.", "A separate window with just the dialogue: put it on a second display, or shrink it to one line so it doesn't cover the game. Buttons appear when you move the pointer over the window."))
            }
            Section {
                SliderRow(title: L("Cỡ chữ", "Font size"), value: $settings.windowFontSize, range: 12...120, step: 1, format: "%.0f")
                Toggle(L("Hiện thêm câu gốc", "Also show the original line"), isOn: Binding(get: { settings.mode == .viAndEn }, set: { settings.mode = $0 ? .viAndEn : .viOnly }))
                    .disabled(settings.mode == .audioOnly)
            } header: { Text(L("Chữ", "Text")) }
            Section {
                AppearanceControls()
            } header: { Text(L("Nền", "Background")) }
            Section {
                Toggle(L("Ghim: nổi trên cùng, theo sang mọi màn hình làm việc", "Pin: float on top and follow to every desktop"), isOn: $subtitleWindow.onTop)
                Note(L("Ghim thì cửa sổ luôn nổi, kể cả cạnh game toàn màn hình.", "When pinned, the window always floats, even next to a full-screen game."))
            } header: { Text(L("Ghim", "Pin")) }
        }
    }

    /// Dòng tóm tắt vùng ở trang tính năng: vùng chỉ chỉnh ở trang Vùng, để không bị hai nơi cùng sửa một thứ.
    private func regionSummary(_ text: String) -> some View {
        LabeledContent(L("Vùng", "Region")) {
            HStack {
                Text(text).foregroundStyle(.secondary)
                Button(L("Mở trang Vùng", "Open Regions")) { nav.page = .capture }.buttonStyle(.link)
            }
        }
    }

    private var displayPage: some View {
        Form {
            Section {
                regionSummary(settings.region.map { "\(Int($0.w)) × \(Int($0.h))" } ?? L("Chưa chọn vùng phụ đề", "No subtitle region selected"))
                Picker(L("Hiện", "Show"), selection: $settings.mode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Note(L("Áp dụng cho cả phụ đề đè lên lẫn cửa sổ app.", "Applies to both the overlay subtitles and the app window."))
            } header: { Text(L("Phụ đề lời thoại", "Dialogue subtitles")) }

            Section {
                Picker(L("Chế độ", "Mode"), selection: $settings.captureMode) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Note(settings.captureMode.detail)
            } header: { Text(L("Cách bắt thoại", "Dialogue capture")) }

            Section {
                Toggle(L("Hiện phụ đề đè lên game", "Show subtitles over the game"), isOn: $settings.overlayEnabled)
                Group {
                    Picker(L("Kiểu", "Style"), selection: $settings.style) {
                        ForEach(OverlayStyle.allCases) { Text($0.title).tag($0) }
                    }
                    SliderRow(title: L("Cỡ chữ", "Font size"), value: $settings.overlayFontScale, range: 60...150, step: 5, format: "%.0f%%")
                    LabeledContent(L("Xem thử trên màn hình", "Preview on screen")) {
                        Button(engine.demoActive ? L("Tắt xem thử", "Stop preview") : L("Xem thử", "Preview")) { engine.toggleDemo() }
                    }
                    // Hai cách đặt phụ đề: đè đúng chỗ chữ gốc (mặc định, app tự lo vị trí, cỡ chữ, căn lề), hoặc tự đặt.
                    Picker(L("Vị trí", "Position"), selection: Binding(get: { settings.overlayFit }, set: { fit in
                        settings.overlayFit = fit
                        if fit { settings.overlayDX = 0; settings.overlayDY = 0; settings.overlayAlign = .auto }
                    })) {
                        Text(L("Đè lên phụ đề gốc", "Over the original")).tag(true)
                        Text(L("Tự đặt", "Custom")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    if settings.overlayFit {
                        Note(L("Vị trí, cỡ chữ và căn lề lấy theo phụ đề gốc của từng câu.", "Position, size and alignment come from each line's original subtitles."))
                    } else {
                        SliderRow(title: L("Dịch ngang", "Horizontal offset"), value: $settings.overlayDX, range: -800...800, step: 2, format: "%+.0f")
                        SliderRow(title: L("Dịch dọc", "Vertical offset"), value: $settings.overlayDY, range: -600...600, step: 2, format: "%+.0f")
                        SliderRow(title: L("Độ rộng tối đa", "Maximum width"), value: $settings.overlayWidthPct, range: 30...200, step: 5, format: "%.0f%%")
                        Note(L("Phụ đề nằm giữa vùng đã chọn, dời theo hai thanh trên. Dùng khi muốn giữ nguyên chữ gốc và đặt bản dịch ở chỗ khác.",
                               "Subtitles sit in the middle of your region, shifted by the sliders above. Use this to keep the original text visible and put the translation elsewhere."))
                    }
                }
                .disabled(!settings.overlayEnabled)
            } header: { Text(L("Phụ đề đè lên", "Overlay subtitles")) } footer: {
                Text(L("Trong game bấm \(HotkeyCenter.Action.toggleOverlay.display) để ẩn hoặc hiện nhanh.", "In game, press \(HotkeyCenter.Action.toggleOverlay.display) to quickly hide or show."))
            }

        }
    }

    // MARK: Bắt thoại

    /// Dịch màn hình: tính năng riêng, dịch tại chỗ chữ ngoài lời thoại.
    private var screenPage: some View {
        Form {
            Section {
                Toggle(isOn: $settings.screenTranslateEnabled) {
                    Text(L("Bật dịch màn hình   \(HotkeyCenter.Action.screenTranslate.display)", "Turn on screen translation   \(HotkeyCenter.Action.screenTranslate.display)"))
                }
                Note(L("Dịch ngay tại chỗ chữ ngoài lời thoại: bảng nhiệm vụ, menu, mô tả vật phẩm, thư từ. Mỗi cụm chữ được thay bằng bản dịch ngay trên nền game, cùng màu chữ, chữ tự co để nằm gọn trong khung giao diện. Không đọc to, không vào Cửa sổ phụ đề hay lịch sử thoại. Bật/tắt ở đây hoặc nút tròn Dịch màn hình; chạy khi bấm Bắt đầu, như Phụ đề và Voice-over.", "Translates text outside the dialogue right where it is: quest logs, menus, item descriptions, letters. Each block of text is replaced by its translation on top of the game, in the same text color, shrinking to fit the interface frame. It isn't read aloud and doesn't go to the Subtitle window or dialogue history. Turn it on or off here or with the round Screen translation button; it runs when you press Start, like Subtitles and Voice-over."))
            } header: { Text(L("Dịch màn hình", "Screen translation")) }
            Section {
                Picker(L("Tốc độ", "Speed"), selection: $settings.screenSpeed) {
                    ForEach(ScreenSpeed.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Note(settings.screenSpeed.detail)
                if settings.screenSpeed != .quality, applePack.state == .downloadable || applePack.state == .unsupported {
                    let src = SourceLanguage.find(settings.sourceLanguage), tgt = settings.target
                    VStack(alignment: .leading, spacing: 8) {
                        Label(applePack.state == .downloadable
                              ? L("Chưa tải gói Dịch máy Apple \(src.displayName) → \(tgt.displayName). Trong lúc chưa có gói, OverSub dùng AI thay nên chậm hơn khoảng 1 đến 2 giây.", "The Apple Translation pack for \(src.displayName) → \(tgt.displayName) isn't downloaded. Until it is, OverSub uses AI instead, which is about 1 to 2 seconds slower.")
                              : L("Dịch máy Apple chưa hỗ trợ \(src.displayName) → \(tgt.displayName). OverSub dùng AI thay nên chậm hơn khoảng 1 đến 2 giây.", "Apple Translation doesn't support \(src.displayName) → \(tgt.displayName) yet. OverSub uses AI instead, which is about 1 to 2 seconds slower."),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if applePack.state == .downloadable {
                            HStack {
                                Button(L("Tải gói dịch", "Download language pack")) { applePack.download(source: src.code, target: tgt.code) }
                                Button(L("Mở Ngôn ngữ & Vùng", "Open Language & Region")) {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            } header: { Text(L("Tốc độ và chất lượng", "Speed and quality")) }
            Section {
                regionSummary(settings.secondaryRegions.isEmpty ? L("Chưa có vùng", "No regions") : L("\(settings.secondaryRegions.count)/\(RegionEditor.maxSecondaries) vùng", "\(settings.secondaryRegions.count)/\(RegionEditor.maxSecondaries) regions"))
                LabeledContent(L("Thêm vùng", "Add region")) {
                    Button(L("Thêm vùng dịch màn hình…", "Add screen region…")) { engine.selectRegion(screen: true) }
                }
                Note(L("Mỗi vùng quét khoảng 0,45 giây một lần. Chữ đổi thì bản dịch cũ được gỡ ngay, chữ mới đứng yên là dịch. Vùng lưu theo hồ sơ game.", "Each region is scanned about every 0.45 seconds. When the text changes, the old translation is removed right away; once the new text settles, it's translated. Regions are saved per game profile."))
            } header: { Text(L("Vùng dịch màn hình", "Screen regions")) }
            Section {
                LabeledContent(L("Dịch nhanh một vùng", "Quick-translate an area")) {
                    HStack {
                        HotkeyField(action: .quickTranslate)
                        Button(L("Thử ngay", "Try it")) { engine.quickTranslate() }
                    }
                }
                if !hotkeys.message.isEmpty { Note(hotkeys.message) }
                Toggle(L("Dừng hình khi dịch nhanh", "Freeze the frame while quick-translating"), isOn: $settings.quickFreeze)
                Note(L("Bấm \(HotkeyCenter.Action.quickTranslate.display) ở bất cứ đâu, kéo một khung quanh chữ, thả chuột là bản dịch hiện ngay tại chỗ. Dùng cho chữ xuất hiện bất chợt (thư, biển hiệu, màn hướng dẫn) mà không cần đặt vùng cố định; không cần bấm Bắt đầu. Dừng hình giúp chọn và đọc không bị trôi; tắt đi thì game vẫn hiện phía sau.",
                       "Press \(HotkeyCenter.Action.quickTranslate.display) anywhere, drag a box around some text, and the translation appears in place when you release. For text that pops up unexpectedly (letters, signs, tutorials) without setting a fixed region; no need to press Start. Freezing keeps the text still while you select and read; turn it off to keep the game visible behind."))
            } header: { Text(L("Dịch nhanh", "Quick translate")) }
        }
        .task(id: settings.sourceLanguage + ">" + settings.targetLanguage) {
            await applePack.check(source: SourceLanguage.find(settings.sourceLanguage).code, target: settings.target.code)
        }
        .translationTask(applePack.request) { session in
            try? await session.prepareTranslation()   // macOS hỏi người dùng rồi tải gói
            await applePack.check(source: SourceLanguage.find(settings.sourceLanguage).code, target: settings.target.code)
        }
    }

    /// Nơi duy nhất xem và sửa vùng: ảnh xem trước mọi vùng (như trang hồ sơ), khung phụ đề và các vùng dịch màn hình.
    private var capturePage: some View {
        Form {
            Section {
                let thumb = settings.activePresetID.flatMap { RegionThumbs.image(for: $0) }
                RegionMap(main: settings.region, secondaries: settings.secondaryRegions, thumbnail: thumb)
                    .padding(.vertical, 4)
                Note(thumb == nil
                     ? L("Chưa có ảnh xem trước. Chọn vùng rồi lưu để có ảnh màn hình kèm các vùng.", "No preview yet. Select a region and save to get a screenshot with the regions.")
                     : L("Ảnh màn hình lúc lưu vùng gần nhất. Viền trắng là vùng phụ đề, viền cam là vùng dịch màn hình.", "Screenshot from the last time regions were saved. The white outline is the subtitle region; orange outlines are screen regions."))
            } header: { Text(L("Xem trước · hồ sơ \(settings.activePreset?.name ?? "")", "Preview · profile \(settings.activePreset?.name ?? "")")) }
            Section {
                LabeledContent(L("Vùng phụ đề", "Subtitle region")) {
                    HStack {
                        if let r = settings.region {
                            Text(L("\(Int(r.w)) × \(Int(r.h)) tại (\(Int(r.x)), \(Int(r.y)))", "\(Int(r.w)) × \(Int(r.h)) at (\(Int(r.x)), \(Int(r.y)))")).foregroundStyle(.secondary)
                        } else {
                            Text(L("Chưa chọn", "Not selected")).foregroundStyle(.secondary)
                        }
                        Button(L("Chọn vùng phụ đề…", "Select subtitle region…")) { engine.selectRegion() }
                    }
                }
                Note(L("Phụ đề lời thoại được nhận trong vùng này. Cách bắt thoại và kiểu hiển thị ở trang Phụ đề.", "Dialogue subtitles are read in this region. Capture mode and display style are on the Subtitles page."))
            } header: { Text(L("Phụ đề lời thoại", "Dialogue subtitles")) }
            Section {
                if settings.secondaryRegions.isEmpty {
                    Note(L("Chưa có vùng nào. Thêm vùng quanh chữ ngoài lời thoại (bảng nhiệm vụ, menu, mô tả vật phẩm) để dịch ngay tại chỗ.", "No regions yet. Add regions around text outside the dialogue (quest logs, menus, item descriptions) to translate it in place."))
                }
                ForEach(Array(settings.secondaryRegions.enumerated()), id: \.offset) { i, r in
                    LabeledContent(L("Vùng \(i + 1)", "Region \(i + 1)")) {
                        HStack {
                            Text(L("\(Int(r.w)) × \(Int(r.h)) tại (\(Int(r.x)), \(Int(r.y)))", "\(Int(r.w)) × \(Int(r.h)) at (\(Int(r.x)), \(Int(r.y)))")).foregroundStyle(.secondary)
                            Button(L("Bỏ", "Remove")) { engine.removeSecondaryRegion(at: i) }
                        }
                    }
                }
                LabeledContent(L("Tối đa \(RegionEditor.maxSecondaries) vùng", "Up to \(RegionEditor.maxSecondaries) regions")) {
                    HStack {
                        Button(L("Thêm vùng dịch màn hình…", "Add screen region…")) { engine.selectRegion(screen: true) }
                        Button(L("Tốc độ và bật/tắt", "Speed and on/off")) { nav.page = .screen }.buttonStyle(.link)
                    }
                }
            } header: { Text(L("Vùng dịch màn hình", "Screen regions")) }

        }
    }
}

/// Mục Cập nhật ở Cài đặt → Chung.
struct UpdateSection: View {
    @ObservedObject private var u = Updater.shared

    var body: some View {
        Section {
            LabeledContent(L("Phiên bản đang dùng", "Current version"), value: Updater.currentVersion)
            LabeledContent(L("Bản mới", "Latest version")) { status }
            if let r = u.pending, !r.notes.isEmpty {
                DisclosureGroup(L("Có gì mới trong bản \(r.version)", "What's new in \(r.version)")) {
                    Text(.init(r.notes)).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Link(L("Xem trên GitHub", "View on GitHub"), destination: r.page).font(.caption)
                }
            }
            Toggle(L("Tự kiểm tra bản mới", "Check for updates automatically"), isOn: $u.autoCheck)
            Toggle(L("Tự tải bản mới và cài khi thoát app", "Download updates automatically and install when quitting"), isOn: $u.autoInstall)
            Note(L("OverSub hỏi trang phát hành trên GitHub khoảng hai lần mỗi ngày, không gửi đi thông tin gì của bạn. Bản tải về được kiểm tra chữ ký số trước khi cài; cài đặt, key và quyền Ghi màn hình giữ nguyên. Bật tự cài thì bản mới được tải sẵn và thay vào lúc bạn thoát app, không làm gián đoạn lúc đang chơi.",
                   "OverSub checks the GitHub releases page about twice a day and sends nothing about you. Downloads are verified with a digital signature before installing; your settings, keys and Screen Recording permission are kept. With automatic install on, the new version is downloaded in the background and swapped in when you quit, so it never interrupts a game."))
        } header: { Text(L("Cập nhật", "Updates")) }
    }

    @ViewBuilder private var status: some View {
        switch u.state {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Đang kiểm tra…", "Checking…")).foregroundStyle(.secondary) }
        case .available(let r):
            HStack {
                Text(L("Có bản \(r.version)", "Version \(r.version) available")).foregroundStyle(.secondary)
                Button(L("Cập nhật", "Update")) { u.updateNow() }
            }
        case .downloading(_, let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 110)
                Text(L("Đang tải \(Int(p * 100))%", "Downloading \(Int(p * 100))%")).monospacedDigit().foregroundStyle(.secondary)
            }
        case .ready(let r, _):
            HStack {
                Text(L("Đã tải bản \(r.version)", "Version \(r.version) downloaded")).foregroundStyle(.secondary)
                Button(u.canInstallInPlace ? L("Cài và mở lại", "Install and relaunch") : L("Mở file cài", "Open installer")) { u.installNow() }
            }
        case .installing:
            Text(L("Đang cài…", "Installing…")).foregroundStyle(.secondary)
        case .upToDate, .idle, .failed:
            HStack {
                Group {
                    if case .failed(let m) = u.state { Text(m).lineLimit(2) }
                    else if case .upToDate = u.state { Text(L("Đang là bản mới nhất", "You're up to date")) }
                    else if let t = u.lastChecked { Text(L("Kiểm tra lần cuối \(t.formatted(date: .abbreviated, time: .shortened))", "Last checked \(t.formatted(date: .abbreviated, time: .shortened))")) }
                }
                .font(.callout).foregroundStyle(.secondary)
                Button(L("Kiểm tra ngay", "Check now")) { Task { await u.check(manual: true) } }
            }
        }
    }
}
