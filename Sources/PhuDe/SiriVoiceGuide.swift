import SwiftUI
import AppKit
import ScreenCaptureKit

/// Trạng thái và hướng dẫn chọn giọng Siri cho ngôn ngữ đang dịch sang. macOS chỉ cho app khác dùng giọng đang được chọn
/// ở System Settings cho từng ngôn ngữ; chưa chọn thì máy đọc bằng giọng mặc định (tiếng Việt là giọng Linh, nghe khá máy).
/// Dùng ở hướng dẫn lần đầu và ở tuỳ chọn giọng đọc.
struct SiriVoiceGuide: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine
    var compact = false

    static func usingSiri(_ base: String) -> Bool {
        // Giọng Siri có mã dạng com.apple.ttsbundle.…; giọng thường (Linh…) là com.apple.voice.…
        Speaker.selectedVoice(forLanguage: base).map(Speaker.isNativeVoice) ?? false
    }

    var body: some View {
        // Đọc lại mỗi 2 giây: người dùng chọn giọng bên System Settings xong quay lại là thấy đổi ngay.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let ok = Self.usingSiri(settings.target.base)
            let lang = settings.target.displayName
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Color.green : Color.secondary)
                    Text(ok ? L("Đang dùng giọng Siri cho \(lang).", "Using a Siri voice for \(lang).")
                            : L("Chưa chọn giọng Siri cho \(lang): máy đang đọc bằng giọng mặc định, nghe khá máy.",
                                "No Siri voice chosen for \(lang): your Mac is using its default voice, which sounds robotic."))
                        .font(compact ? .callout : .body).fixedSize(horizontal: false, vertical: true)
                }
                if !ok || !compact {
                    VStack(alignment: .leading, spacing: 5) {
                        step(1, L("Mở System Settings → Accessibility → Read & Speak.", "Open System Settings → Accessibility → Read & Speak."))
                        step(2, L("Bấm ⓘ cạnh System voice, chọn \(settings.target.english) ở danh sách bên trái.", "Click ⓘ next to System voice and choose \(settings.target.english) in the list on the left."))
                        step(3, L("Bấm Voice, chọn một giọng Siri (nếu giọng có biểu tượng đám mây, hãy tải về trước).", "Click Voice and pick a Siri voice (download it first if it shows a cloud)."))
                    }
                }
                HStack(spacing: 10) {
                    Button(ok ? L("Đổi giọng Siri…", "Change Siri voice…") : L("Mở System Settings", "Open System Settings")) {
                        SiriGuidePanel.shared.show()
                    }
                    Button { engine.previewVoice() } label: { Label(L("Nghe thử", "Preview"), systemImage: "play.fill") }
                }
                .controlSize(compact ? .small : .regular)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).monospacedDigit()
                .frame(width: 18, height: 18).background(Color.primary.opacity(0.1), in: Circle())
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// Dẫn từng bước đổi giọng Siri ngay trên System Settings. App mở thẳng trang Read & Speak, rồi cứ khoảng một giây chụp
/// cửa sổ System Settings và đọc chữ trong đó (bằng chính bộ đọc chữ của app, không cần thêm quyền) để biết người dùng
/// đang ở bước nào và nút cần bấm nằm ở đâu: bảng nhỏ nêu việc cần làm, một vòng sáng khoanh đúng nút. Giọng đổi xong thì
/// báo, đọc thử và tự đóng. System Settings không phải tiếng Anh thì không nhận được chữ: bảng hiện đủ các bước dạng chữ.
@MainActor
final class SiriGuidePanel: ObservableObject {
    static let shared = SiriGuidePanel()

    enum Step: Int { case open = 0, pane, info, language, voice, pick, done }
    @Published var step: Step = .open
    @Published var located = false        // đã tìm thấy nút cần bấm trên màn hình
    @Published var recognized = false     // đọc được giao diện System Settings (tiếng Anh)

    private var panel: NSPanel?
    private var ring: NSPanel?
    private var startVoice: String?
    private var loop: Task<Void, Never>?
    private var misses = 0
    private var lastTick = 0.0   // thời gian một lần chụp và đọc, ghi vào nhật ký khi đổi bước
    private var docked = false   // đã đặt bảng cạnh cửa sổ System Settings (chỉ làm một lần, sau đó tôn trọng chỗ người dùng kéo tới)

    func show() {
        let base = AppModel.shared.settings.target.base
        startVoice = Speaker.selectedVoice(forLanguage: base)
        step = .open; located = false; recognized = false; misses = 0; docked = false
        // Mở thẳng trang Read & Speak.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") { NSWorkspace.shared.open(url) }
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame { place(p, x: v.maxX - p.frame.width - 20, top: v.maxY - 20, within: v) }
        p.orderFrontRegardless()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                await self?.tick()
            }
        }
    }

    /// Đặt bảng, luôn nằm trọn trong vùng nhìn thấy của màn hình.
    private func place(_ p: NSPanel, x: CGFloat, top: CGFloat, within v: NSRect) {
        p.layoutIfNeeded()
        let size = p.frame.size
        let px = min(max(v.minX + 12, x), v.maxX - size.width - 12)
        let py = min(max(v.minY + 12, top - size.height), v.maxY - size.height - 12)
        p.setFrameOrigin(NSPoint(x: px, y: py))
    }

    /// Đặt bảng sát cạnh cửa sổ System Settings (bên phải, hết chỗ thì bên trái), ngang mép trên cửa sổ.
    private func dock(to area: CGRect) {
        guard !docked, let p = panel, let primary = NSScreen.screens.first else { return }
        docked = true
        let cocoa = NSRect(x: area.minX, y: primary.frame.height - area.maxY, width: area.width, height: area.height)
        guard let v = (NSScreen.screens.first { $0.frame.intersects(cocoa) } ?? NSScreen.main)?.visibleFrame else { return }
        let w = p.frame.width
        let h = p.frame.height
        let roomRight = v.maxX - cocoa.maxX, roomLeft = cocoa.minX - v.minX
        if roomRight >= w + 34 {
            place(p, x: cocoa.maxX + 24, top: cocoa.maxY, within: v)   // bảng chọn giọng rộng hơn cửa sổ chính khoảng 10 điểm mỗi bên
        } else if roomLeft >= w + 34 {
            place(p, x: cocoa.minX - 24 - w, top: cocoa.maxY, within: v)
        } else if cocoa.minY - v.minY >= h + 20 {
            // Hai bên không đủ chỗ: đặt ngay dưới cửa sổ.
            place(p, x: cocoa.maxX - w, top: cocoa.minY - 10, within: v)
        } else if v.maxY - cocoa.maxY >= h + 20 {
            place(p, x: cocoa.maxX - w, top: cocoa.maxY + 10 + h, within: v)
        } else {
            // Không còn chỗ trống nào đủ: nép vào góc dưới của màn hình ở phía rộng hơn, che cửa sổ ít nhất có thể
            // (các nút cần bấm nằm ở nửa trên cửa sổ).
            place(p, x: roomRight >= roomLeft ? v.maxX - w : v.minX, top: v.minY + h, within: v)
        }
    }

    func close() {
        loop?.cancel(); loop = nil
        ring?.orderOut(nil)
        panel?.orderOut(nil)
    }

    // MARK: Nhận biết bước

    private func tick() async {
        guard panel?.isVisible == true, step != .done else { return }
        let tickStart = Date()
        defer { lastTick = Date().timeIntervalSince(tickStart) }
        let settings = AppModel.shared.settings
        // Giọng đã khác lúc mở và là giọng Siri: xong.
        let now = Speaker.selectedVoice(forLanguage: settings.target.base)
        if now != startVoice, now.map(Speaker.isNativeVoice) ?? false {
            step = .done
            ring?.orderOut(nil)
            AppModel.shared.engine.speaker.resetSystemVoice()   // để lần đọc tới dùng giọng mới
            AppModel.shared.engine.previewVoice()
            DebugLog.write("Hướng dẫn giọng Siri: đã đổi giọng")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.step == .done { self?.close() } }
            return
        }
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let wins = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.systempreferences" && $0.isOnScreen
            && $0.frame.width > 300 && $0.frame.height > 200 }
        guard !wins.isEmpty else { set(.open, target: nil); return }

        // Chụp đúng vùng màn hình chứa các cửa sổ System Settings (cửa sổ chính và bảng chọn giọng), không chụp riêng từng
        // cửa sổ: ảnh chụp riêng cửa sổ có bảng con bị co lại so với khung cửa sổ nên vị trí chữ tính ra bị lệch. Chụp theo
        // vùng màn hình thì điểm ảnh khớp đúng toạ độ màn hình.
        var area = wins.map(\.frame).reduce(wins[0].frame) { $0.union($1) }
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }) else { return }
        area = area.intersection(display.frame)
        dock(to: wins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.frame ?? area)
        let pid = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == pid }   // không chụp bảng hướng dẫn và vòng sáng của chính app
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        // 1,4 lần là đủ nét để đọc chữ giao diện và nhanh gần gấp đôi so với 2 lần: bảng chuyển bước kịp tay người dùng.
        cfg.width = Int(area.width * 1.4); cfg.height = Int(area.height * 1.4)
        cfg.showsCursor = false
        let title = wins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.title ?? ""
        var candidates: [(step: Step, target: CGRect?)] = []
        var anyText = false
        if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), configuration: cfg),
           let res = try? await OCR.recognize(img, language: "en-US", keepAll: true) {
            let w = (frame: area, title: Optional(title))
            repeat {
            let lines = res.lines.map { (text: $0.text.lowercased(), box: $0.box) }
            if lines.contains(where: { $0.text.contains("system voice") || $0.text.contains("speech volume") || $0.text.contains("accessibility") || $0.text == "siri" }) { anyText = true }
            // Toạ độ màn hình (gốc trên trái) của một dòng chữ.
            func rect(_ b: CGRect) -> CGRect {
                CGRect(x: w.frame.minX + b.minX * w.frame.width, y: w.frame.minY + (1 - b.maxY) * w.frame.height,
                       width: b.width * w.frame.width, height: b.height * w.frame.height)
            }
            let lang = settings.target.english.lowercased()
            let right = lines.map { rect($0.box).maxX }.max() ?? w.frame.maxX - 30
            // Bảng chi tiết một ngôn ngữ: danh sách ngôn ngữ bên trái; bên phải là tiêu đề (tên ngôn ngữ đang chọn) và các hàng
            // Voice, Rate, Pitch, Speech Volume.
            if let anchor = lines.first(where: { $0.text.contains("speech volume") }) ?? lines.first(where: { $0.text.contains("reset voice settings") }) {
                // Mép trái của phần bên phải, lấy theo hàng "Speech Volume" (không đoán theo tỉ lệ cố định).
                let split = anchor.box.minX - 0.04
                let chosen = lines.contains { $0.box.minX > split && $0.text == lang }
                if !chosen {
                    let row = lines.filter { $0.box.minX < split && $0.text.hasPrefix(lang) }.first
                    candidates.append((.language, row.map { rect($0.box).insetBy(dx: -14, dy: -8) }))
                } else if let v = lines.first(where: { $0.box.minX > split && $0.text.hasPrefix("voice") }) {
                    let r = rect(v.box)
                    candidates.append((.voice, CGRect(x: r.minX - 12, y: r.minY - 10, width: right - r.minX + 24, height: r.height + 20)))
                } else {
                    candidates.append((.voice, nil))
                }
                break
            }
            // Danh sách giọng: tiêu đề "Voice", ô Search, mục "Siri" với các hàng "Voice 1", "Voice 2"…
            // Nhận theo tiêu đề "Voice" đứng riêng một dòng (trang chính không có dòng nào như vậy; thanh bên của trang chính
            // cũng có "Search" và "Siri" nên không dùng hai chữ đó để nhận).
            // Danh sách giọng: có dòng tiêu đề "Voice" đứng riêng và ô Search bên dưới. Mục "Siri" có thể chưa hiện (danh
            // sách dài như tiếng Anh phải cuộn mới tới), nên không bắt buộc thấy nó mới nhận là bước này.
            if let head = lines.filter({ $0.text == "voice" }).max(by: { $0.box.midY < $1.box.midY }),
               case let split = head.box.minX - 0.06,
               lines.contains(where: { $0.box.minX > split && $0.box.midY < head.box.midY && $0.text.hasSuffix("search") }) {
                let siriHeads = lines.filter { $0.box.minX > split && $0.text == "siri" }
                let top = siriHeads.map(\.box.midY).max() ?? -1
                let voices = lines.filter { l in
                    l.box.minX > split && l.box.midY < top && l.text.range(of: #"^voice \d"#, options: .regularExpression) != nil
                }
                // Thấy giọng Siri trong danh sách thì báo "đã thấy"; chưa thấy thì bảng nhắc cuộn.
                candidates.append((.pick, voices.isEmpty ? nil : CGRect(x: 0, y: 0, width: 1, height: 1)))
                break
            }
            if let sv = lines.first(where: { $0.text.contains("system voice") }) {
                // Nút ⓘ nằm cuối hàng "System voice", cách mép phải cửa sổ khoảng 40 điểm.
                let r = rect(sv.box)
                candidates.append((.info, CGRect(x: w.frame.maxX - 40 - 15, y: r.midY - 15, width: 30, height: 30)))
            } else if (w.title ?? "") == "Read & Speak" {
                candidates.append((.info, nil))   // đúng trang nhưng hàng System voice bị cuộn khuất
            } else if let rs = lines.first(where: { $0.text.contains("read & speak") && $0.box.minX > 0.3 }) {
                candidates.append((.pane, rect(rs.box).insetBy(dx: -12, dy: -8)))
            } else if let acc = lines.first(where: { $0.text == "accessibility" && $0.box.minX < 0.3 }) {
                candidates.append((.pane, rect(acc.box).insetBy(dx: -14, dy: -8)))
            } else {
                candidates.append((.pane, nil))
            }
        } while false
        }
                let found = candidates.max { $0.step.rawValue < $1.step.rawValue }
        guard panel?.isVisible == true, step != .done else { return }
        if anyText { recognized = true; misses = 0 } else { misses += 1; if misses >= 4 { recognized = false } }
        if let found { set(found.step, target: found.target) } else { ring?.orderOut(nil); located = false }
    }

    private func set(_ s: Step, target: CGRect?) {
        if step != s { step = s; DebugLog.write(String(format: "Hướng dẫn giọng Siri: bước %d%@ (lần đọc trước %.2f s)", s.rawValue, target == nil ? " (chưa thấy)" : "", lastTick)) }
        located = target != nil
        // Không khoanh nút trên System Settings nữa: danh sách bước có dấu tích là đủ, và không còn rủi ro khoanh lệch.
    }

    // MARK: Cửa sổ

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 308, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: SiriGuidePanelView(panel: self)
            .environmentObject(AppModel.shared.settings).environmentObject(AppModel.shared.engine))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        p.setContentSize(host.fittingSize)
        return p
    }

    /// Vòng sáng khoanh nút cần bấm: bấm xuyên qua được, nằm trên System Settings.
    private func makeRing() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: PulseRing())
        return p
    }
}

/// Vòng cam nhấp nháy nhẹ quanh nút cần bấm.
private struct PulseRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let k = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 4.2)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.gradient, lineWidth: 2.5)
                .opacity(0.55 + 0.45 * k)
                .padding(2 - 2 * k)
                .shadow(color: Theme.orangeEnd.opacity(0.7), radius: 4 + 4 * k)
        }
        .ignoresSafeArea()
    }
}

private struct SiriGuidePanelView: View {
    @ObservedObject var panel: SiriGuidePanel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: Engine

    private var texts: [String] {
        [L("Mở Accessibility → Read & Speak.", "Open Accessibility → Read & Speak."),
         L("Bấm ⓘ ở cuối hàng System voice.", "Click ⓘ at the end of the System voice row."),
         L("Chọn \(settings.target.english) ở danh sách bên trái.", "Choose \(settings.target.english) in the list on the left."),
         L("Bấm hàng Voice.", "Click the Voice row."),
         L("Chọn một giọng dưới mục Siri, rồi bấm Done.", "Pick a voice under Siri, then click Done.")]
    }

    var body: some View {
        // Bước đang làm (1...4); 0 = chưa thấy System Settings.
        let cur = max(1, min(5, panel.step.rawValue))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                Text(L("Chọn giọng Siri", "Choose a Siri voice")).font(.subheadline.weight(.semibold))
                Spacer()
                if panel.step != .done { Text("\(cur)/5").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Button { panel.close() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.borderless).help(L("Đóng", "Close"))
            }
            if panel.step == .done {
                Label(L("Đã đổi giọng. Đang đọc thử…", "Voice changed. Playing a sample…"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(1...5, id: \.self) { n in
                        // Không đọc được System Settings (không phải tiếng Anh): hiện đều cả năm bước.
                        let state: Int = !panel.recognized ? 0 : n < cur ? -1 : n == cur ? 1 : 2
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Group {
                                if state == -1 { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                                else { Text("\(n)").font(.caption.weight(.bold)).monospacedDigit() }
                            }
                            .frame(width: 18, height: 18)
                            .background(state == 1 ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)), in: Circle())
                            .foregroundStyle(state == 1 ? Color.white : Color.primary)
                            Text(texts[n - 1]).font(state == 1 ? .footnote.weight(.semibold) : .footnote)
                                .foregroundStyle(state == 1 || state == 0 ? Color.primary : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { engine.previewVoice() } label: { Label(L("Nghe thử", "Preview"), systemImage: "play.fill") }
                Spacer()
                Button(L("Xong", "Done")) { panel.close() }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .animation(.smooth(duration: 0.25), value: panel.step)
    }

    private var hint: String {
        if !panel.recognized { return L("Làm lần lượt các bước trên. Bảng này tự đóng khi bạn chọn xong.", "Follow the steps above. This panel closes by itself once you've picked a voice.") }
        if panel.step == .pick, panel.located { return L("Nếu giọng có biểu tượng đám mây, hãy bấm vào đó để tải về trước.", "If a voice shows a cloud, click the cloud to download it first.") }
        if panel.located { return L("Bảng tự chuyển bước khi bạn làm xong.", "The panel moves on by itself.") }
        switch panel.step {
        case .open: return L("Đang chờ System Settings mở…", "Waiting for System Settings to open…")
        case .info: return L("Cuộn xuống trong trang Read & Speak để thấy hàng System voice.", "Scroll down in Read & Speak to find the System voice row.")
        case .pick: return L("Cuộn danh sách giọng để thấy mục Siri.", "Scroll the voice list to find the Siri section.")
        case .language: return L("Cuộn danh sách bên trái để tìm \(settings.target.english).", "Scroll the list on the left to find \(settings.target.english).")
        default: return L("Bảng này tự đóng khi bạn chọn xong.", "This panel closes by itself once you've picked a voice.")
        }
    }
}
