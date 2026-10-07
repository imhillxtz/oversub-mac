import SwiftUI
import AppKit
import Translation

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = UserDefaults.standard.integer(forKey: "onboardStep")   // thường là 0; đặt qua tham số để chụp kiểm tra
    @Published var permissionGranted = CGPreflightScreenCaptureAccess()
}

/// Hướng dẫn lần đầu, bốn bước: giới thiệu và cấp quyền, ngôn ngữ, chọn tính năng, chọn vùng.
/// Xuyên suốt nhấn một ý: Phụ đề và Giọng đọc cùng lo LỜI THOẠI (chung một vùng phụ đề, giọng chỉ đọc lời thoại);
/// Dịch màn hình lo CHỮ GIAO DIỆN (vùng riêng, không đọc to).
struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var hub: TranslationHub
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OnboardingModel()
    @StateObject private var keyForm = KeyForm(provider: .gemini)
    @StateObject private var applePack = ApplePackCheck()

    private let steps = 5

    private var title: String {
        switch model.step {
        case 0: return L("Chơi game tiếng nào cũng hiểu", "Understand any game, in your language")
        case 1: return L("Game tiếng gì, dịch sang tiếng gì?", "Which languages?")
        case 2: return L("Bạn muốn dùng gì?", "What do you want to use?")
        case 3: return L("Chọn giọng đọc cho dễ nghe", "Pick a voice that sounds good")
        default: return L("Chỉ cho OverSub chỗ có chữ", "Show OverSub where the text is")
        }
    }

    private var subtitle: String {
        switch model.step {
        case 0: return L("OverSub nhận chữ trong game ngay trên màn hình và dịch tại chỗ.", "OverSub reads in-game text right off the screen and translates it in place.")
        case 1: return L("Đổi lại bất cứ lúc nào trong Cài đặt.", "You can change this any time in Settings.")
        case 2: return L("Ba tính năng bật tắt độc lập, bằng ba nút tròn ở cửa sổ chính.", "Three independent features, toggled with the three round buttons in the main window.")
        case 3: return L("OverSub đọc bằng giọng Siri bạn chọn trong macOS. Chỉ cần chọn một lần.", "OverSub reads with the Siri voice you choose in macOS. You only do this once.")
        default: return L("Mở game, rồi kéo một khung quanh chỗ cần dịch. Mỗi game chỉ cần làm một lần.", "Open your game and drag a box around the text. Once per game.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Đầu trang: tên app và tiến độ. (Ngôn ngữ giao diện theo máy; đổi ở Cài đặt → Chung.)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("OverSub").font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i <= model.step ? Color.primary.opacity(0.85) : Color.primary.opacity(0.15))
                            .frame(width: i == model.step ? 26 : 14, height: 4)
                    }
                }
            }
            .padding(.bottom, 26)

            Text(title).font(.system(size: 26, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.body).foregroundStyle(.secondary).padding(.top, 4).fixedSize(horizontal: false, vertical: true)

            Group {
                switch model.step {
                case 0: welcomeStep
                case 1: languageStep
                case 2: featureStep
                case 3: voiceStep
                default: regionStep
                }
            }
            .padding(.top, 22)
            // Mọi bước cùng một chiều cao: thẻ không nhảy kích thước giữa các bước và hàng nút luôn ở đúng một chỗ.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 330, alignment: .topLeading)
            .transition(.opacity.combined(with: .offset(x: 16)))
            .id(model.step)

            HStack {
                Button(L("Bỏ qua hướng dẫn", "Skip the guide")) { finish() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()
                if model.step > 0 { Button(L("Quay lại", "Back")) { model.step -= 1 }.controlSize(.large) }
                if model.step < steps - 1 {
                    Button { model.step += 1 } label: { Text(L("Tiếp tục", "Continue")).padding(.horizontal, 10) }
                        .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Để sau", "Later")) { finish() }.controlSize(.large)
                }
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 640)
        // Giữ đúng chiều cao của nội dung dù cửa sổ chính đang thấp: không thì thẻ bị ép lại, chữ và nút đè lên nhau.
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: model.step)
    }

    // MARK: Khối dùng chung

    /// Thẻ nền mờ bo góc, có thể kèm nhãn nhỏ phía trên.
    private func card<C: View>(_ label: String? = nil, note: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                HStack(spacing: 6) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).kerning(0.6)
                    if let note { Text("· " + note).font(.caption).foregroundStyle(.tertiary) }
                }
                .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    /// Biểu tượng trong ô vuông bo góc.
    private func badge(_ icon: String, size: CGFloat = 36) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private func row(_ icon: String, _ name: String, _ detail: String, toggle: Binding<Bool>? = nil) -> some View {
        HStack(spacing: 12) {
            badge(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let toggle { Toggle("", isOn: toggle).labelsHidden().toggleStyle(.switch) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// Ô chọn có bề ngang cố định, để các ô xếp chồng thẳng mép nhau (ô chọn của hệ thống co theo chữ nên lệch).
    private func choiceMenu<C: View>(_ current: String, @ViewBuilder _ items: () -> C) -> some View {
        Menu { items() } label: {
            HStack(spacing: 6) {
                Text(current).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(width: 220, height: 30)
            .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var hairline: some View { Divider().padding(.leading, 62).opacity(0.6) }

    // MARK: Bước 1: giới thiệu và quyền

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(L("Lời thoại", "Dialogue")) {
                row("captions.bubble.fill", L("Phụ đề", "Subtitles"), L("Bản dịch đè ngay lên phụ đề gốc của game.", "The translation sits right over the game's own subtitles."))
                hairline
                row("waveform", L("Giọng đọc", "Voice"), L("Đọc to lời thoại đã dịch, để bạn khỏi phải đọc chữ.", "Reads the translated dialogue aloud, so you don't have to read."))
            }
            card(L("Chữ giao diện", "Interface text")) {
                row("text.viewfinder", L("Dịch màn hình", "Screen translation"), L("Menu, bảng nhiệm vụ, mô tả vật phẩm được dịch tại chỗ.", "Menus, quest logs and item text are translated in place."))
            }
            // Quyền Ghi màn hình: điều kiện duy nhất để chạy.
            HStack(spacing: 10) {
                Image(systemName: model.permissionGranted ? "checkmark.seal.fill" : "lock.fill")
                    .foregroundStyle(model.permissionGranted ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                if model.permissionGranted {
                    Text(L("Đã có quyền Ghi màn hình. Ảnh màn hình không rời khỏi máy.", "Screen Recording is allowed. Screenshots never leave your Mac."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Cần quyền Ghi màn hình để nhận chữ", "Screen Recording is needed to read the text")).font(.callout.weight(.medium))
                        Text(L("Bật OverSub trong danh sách, sau đó thoát hẳn và mở lại app. Ảnh màn hình không rời khỏi máy.", "Turn on OverSub in the list, then quit and reopen the app. Screenshots never leave your Mac."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(L("Kiểm tra", "Check")) { model.permissionGranted = CGPreflightScreenCaptureAccess() }.buttonStyle(.borderless)
                    Button(L("Cấp quyền", "Allow")) {
                        CGRequestScreenCaptureAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Bước 2: ngôn ngữ

    private var languageStep: some View {
        let src = SourceLanguage.find(settings.sourceLanguage), tgt = settings.target
        return VStack(alignment: .leading, spacing: 14) {
            card {
                HStack(spacing: 12) {
                    badge("gamecontroller.fill")
                    Text(L("Game dùng", "Game language")).font(.body.weight(.semibold))
                    Spacer()
                    choiceMenu(src.displayName) {
                        ForEach(SourceLanguage.all) { l in Button(l.displayName) { settings.sourceLanguage = l.ocr } }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                hairline
                HStack(spacing: 12) {
                    badge("globe")
                    Text(L("Dịch sang", "Translate to")).font(.body.weight(.semibold))
                    Spacer()
                    choiceMenu(tgt.displayName) {
                        ForEach(TargetLanguage.all) { l in Button(l.displayName) { settings.targetLanguage = l.code } }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                hairline
                // Dịch máy Apple: dùng ngay không cần key, nhưng phải có gói ngôn ngữ trên máy.
                HStack(spacing: 8) {
                    switch applePack.state {
                    case .installed:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(L("Sẵn sàng dịch ngay trên máy, không cần key, không cần mạng.", "Ready to translate on-device: no key, no network."))
                    case .downloadable:
                        Image(systemName: "arrow.down.circle")
                        Text(L("Tải gói \(src.displayName) → \(tgt.displayName) của Apple để dịch ngay trên máy.", "Download Apple's \(src.displayName) → \(tgt.displayName) pack to translate on-device."))
                        Spacer(minLength: 6)
                        Button(L("Tải gói", "Download")) { applePack.download(source: src.code, target: tgt.code) }
                    case .unsupported:
                        Image(systemName: "exclamationmark.triangle")
                        Text(L("Apple chưa có gói dịch trên máy cho cặp này, nên bạn cần thêm key bên dưới.", "Apple has no on-device pack for this pair: add a key below."))
                    case .unknown:
                        Text(L("Đang kiểm tra gói dịch trên máy…", "Checking the on-device pack…"))
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            card(L("Dịch hay hơn", "Better translations"), note: L("không bắt buộc", "optional")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Bạn nên thêm key Gemini miễn phí để bản dịch đúng xưng hô và văn phong game. Khi có key, chữ trong vùng bạn chọn được gửi tới Google để dịch.",
                           "Add a free Gemini key for translations with the right tone and character voice. With a key, text in your regions is sent to Google for translation."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(L("Dán key Gemini", "Paste Gemini key"), text: Binding(get: { keyForm.input }, set: { keyForm.input = $0 }))
                            .textFieldStyle(.roundedBorder)
                        Button(keyForm.checking ? L("Đang kiểm tra…", "Checking…") : L("Thêm", "Add")) { keyForm.submit(hub: hub) }
                            .disabled(keyForm.checking || keyForm.input.trimmingCharacters(in: .whitespaces).isEmpty)
                        Link(L("Lấy key", "Get a key"), destination: URL(string: "https://aistudio.google.com/apikey")!).font(.callout)
                    }
                    if !keyForm.message.isEmpty {
                        Text(keyForm.message).font(.caption).foregroundStyle(keyForm.ok ? Color.green : Color.red)
                    }
                }
                .padding(14)
            }
        }
        .task(id: settings.sourceLanguage + ">" + settings.targetLanguage) {
            await applePack.check(source: src.code, target: tgt.code)
        }
        .translationTask(applePack.request) { session in
            try? await session.prepareTranslation()
            await applePack.check(source: SourceLanguage.find(settings.sourceLanguage).code, target: settings.target.code)
        }
    }

    // MARK: Bước 3: tính năng

    private var featureStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            card(L("Lời thoại", "Dialogue"), note: L("dùng chung một vùng phụ đề", "share one subtitle region")) {
                row("captions.bubble.fill", L("Phụ đề", "Subtitles"),
                    L("Bản dịch đè ngay lên phụ đề gốc của game.", "The translation sits right over the game's own subtitles."),
                    toggle: $settings.overlayEnabled)
                hairline
                row("waveform", L("Giọng đọc", "Voice"),
                    L("Đọc to lời thoại đã dịch bằng giọng Siri. Chỉ đọc lời thoại, không đọc menu.", "Reads translated dialogue aloud with a Siri voice. Dialogue only, not menus."),
                    toggle: Binding(get: { settings.speakEnabled }, set: { settings.speakEnabled = $0 }))
            }
            card(L("Chữ giao diện", "Interface text"), note: L("vùng riêng, không đọc to", "its own regions, never read aloud")) {
                row("text.viewfinder", L("Dịch màn hình", "Screen translation"),
                    L("Menu, bảng nhiệm vụ, mô tả vật phẩm được dịch tại chỗ.", "Menus, quest logs and item text are translated in place."),
                    toggle: $settings.screenTranslateEnabled)
            }
            Text(L("Nếu chỉ muốn nghe mà không cần chữ, hãy tắt Phụ đề và giữ Giọng đọc; giọng vẫn đọc lời thoại trong vùng phụ đề.",
                   "Just want to listen? Turn off Subtitles and keep Voice: it still reads the dialogue in the subtitle region."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bước 4: giọng đọc

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            card { SiriVoiceGuide().padding(16) }
            Text(settings.speakEnabled
                 ? L("Giọng Siri nghe tự nhiên hơn giọng mặc định. Đổi lại lúc nào cũng được, ở nút tuỳ chọn trên thanh giọng đọc.", "Siri voices sound more natural than the default voice. You can change it any time from the options button on the voice bar.")
                 : L("Bạn đang tắt Giọng đọc nên có thể bỏ qua bước này.", "Voice is turned off, so you can skip this step."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bước 5: vùng

    private var regionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                regionTile(icon: "captions.bubble.fill", name: L("Vùng phụ đề", "Subtitle region"),
                           serves: L("Cho Phụ đề và Giọng đọc", "For Subtitles and Voice"),
                           detail: L("Kéo quanh hộp thoại của nhân vật, gồm cả nhãn tên nếu có.", "Drag around the character dialogue box, including the name label if there is one."),
                           button: L("Chọn vùng phụ đề", "Pick subtitle region"), primary: true) { pick(screen: false) }
                regionTile(icon: "text.viewfinder", name: L("Vùng dịch màn hình", "Screen region"),
                           serves: L("Cho Dịch màn hình", "For Screen translation"),
                           detail: L("Kéo quanh menu, bảng nhiệm vụ hay mô tả vật phẩm. Tối đa 3 vùng.", "Drag around a menu, quest log or item description. Up to 3 regions."),
                           button: L("Thêm vùng dịch", "Add screen region"), primary: false) { pick(screen: true) }
            }
            Text(L("Trong game: \(HotkeyCenter.Action.toggleRunning.display) bắt đầu/dừng · \(HotkeyCenter.Action.toggleOverlay.display) phụ đề · \(HotkeyCenter.Action.toggleDub.display) giọng đọc · \(HotkeyCenter.Action.screenTranslate.display) dịch màn hình · \(HotkeyCenter.Action.selectRegion.display) chọn vùng",
                   "In game: \(HotkeyCenter.Action.toggleRunning.display) start/stop · \(HotkeyCenter.Action.toggleOverlay.display) subtitles · \(HotkeyCenter.Action.toggleDub.display) voice · \(HotkeyCenter.Action.screenTranslate.display) screen translation · \(HotkeyCenter.Action.selectRegion.display) pick region"))
                .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 4)
        }
    }

    private func regionTile(icon: String, name: String, serves: String, detail: String, button: String, primary: Bool,
                            action: @escaping () -> Void) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                // Hình minh hoạ: một màn hình game nhỏ với vùng được khoanh.
                ZStack(alignment: primary ? .bottom : .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .foregroundStyle(.primary.opacity(0.75))
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay { Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
                        .frame(width: primary ? 190 : 84, height: primary ? 26 : 50)
                        .padding(10)
                }
                .frame(height: 84)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.body.weight(.semibold))
                    Text(serves).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if primary {
                    Button(action: action) { Text(button).frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).tint(Theme.accent).controlSize(.large)
                } else {
                    Button(action: action) { Text(button).frame(maxWidth: .infinity) }
                        .buttonStyle(.glass).controlSize(.large)
                }
            }
            .padding(14)
            .frame(height: 262, alignment: .top)
        }
    }

    private func pick(screen: Bool) {
        finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { engine.selectRegion(screen: screen) }
    }

    private func finish() {
        settings.onboardingDone = true
        dismiss()
    }
}
